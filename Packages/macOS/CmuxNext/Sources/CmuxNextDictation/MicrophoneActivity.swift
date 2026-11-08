import AppKit
import AVFoundation
import CmuxNextWakeups
import CoreAudio

/// Whether another app is using the microphone, for the composer's outside-dictation indicator
/// (design/composer-dictation.md). It only reads CoreAudio properties: each input device's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere`, and on macOS 14.2 and later the audio process
/// objects' `kAudioProcessPropertyIsRunningInput`, to name the app that holds it.
///
/// It opens the microphone only for a meter, and only while all of these hold: someone watches,
/// another app's input runs, macOS is 14.2 or later (before, a running device cannot tell this tap
/// from the other app's input, so its release would never be seen), cmux already has microphone
/// permission (read, never asked for), and cmux's own dictation does not hold the microphone. The
/// meter's tap (``MicrophoneLevelTap``) keeps levels only, no samples, and closes the moment one
/// of those stops holding. Without it the page draws its own pulse.
///
/// Listeners run only while someone watches (a focused composer, ``watch(_:onLevel:onChange:)``):
/// the last ``unwatch(_:)`` removes them, so no observer runs while no composer has the keyboard.
@MainActor
public final class MicrophoneActivity {
    /// What the composer shows.
    public struct State: Equatable, Sendable {
        /// Some other app's input runs.
        public var active: Bool
        /// The app holding it, when macOS says (14.2 and later), else nil.
        public var bundleId: String?
        /// That app's name.
        public var name: String?
        /// cmux meters the input level for this outside session (``watch(_:onLevel:onChange:)``'s levels).
        public var metered = false

        public static let idle = State(active: false, bundleId: nil, name: nil)
    }

    private struct Watcher {
        let onChange: (State) -> Void
        let onLevel: ((Float) -> Void)?
    }

    private var watchers: [ObjectIdentifier: Watcher] = [:]
    public private(set) var state = State.idle
    /// The input devices listened to, each with its `IsRunningSomewhere` listener: every input,
    /// not only the default one, since an app may record from any of them.
    private var devices: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var processBlock: AudioObjectPropertyListenerBlock?
    /// The default input's listener: a running meter moves to the new device.
    private var defaultInputBlock: AudioObjectPropertyListenerBlock?
    /// Each other process's `IsRunningInput` listener (14.2 and later): while the meter's own tap
    /// runs, the device stays running because of it, so the other app's release shows only here.
    private var processes: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// A second read shortly after a process-list change: a process joins the list before its
    /// input starts, so the first read can miss it.
    private let settle = DemandTimer(owner: "microphone-activity.settle")

    /// Reads the state now (tests pass their own).
    var read: @MainActor (_ devices: [AudioObjectID]) -> State = { MicrophoneActivity.readState(devices: $0) }
    /// Whether listeners are installed (tests).
    var isListening: Bool {
        !devices.isEmpty || systemBlock != nil || processBlock != nil || defaultInputBlock != nil || !processes.isEmpty
    }

    /// cmux's own dictation: while it holds the microphone no meter runs.
    private let claims: DictationMicrophoneClaims
    /// The running meter, while ``State/metered``.
    private var levelMeter: DictationAudioLevelMeter?
    /// Forwards the meter's levels to the watchers; ends when the meter finishes.
    private(set) var levelForwarding: Task<Void, Never>?
    /// The tap closed on its own (a failed start) during this outside session:
    /// it opens again only for the next one.
    private var meterEnded = false

    /// Whether macOS names the processes whose input runs (14.2 and later; tests set it).
    var tellsProcessesApart: Bool = {
        if #available(macOS 14.2, *) { return true }
        return false
    }()
    /// Whether cmux has microphone permission. A read that never prompts; nothing here asks for it.
    var isAuthorized: @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    /// Opens the meter-only tap into a meter (tests pass their own).
    var openMeter: @MainActor (DictationAudioLevelMeter) -> Void
    /// Closes it.
    var closeMeter: @MainActor () -> Void

    public init(claims: DictationMicrophoneClaims = .shared) {
        self.claims = claims
        let tap = MicrophoneLevelTapControl()
        openMeter = { tap.open($0) }
        closeMeter = { tap.close() }
    }

    /// `owner` wants the state: told now, then on every change, until ``unwatch(_:)``. While the
    /// state is ``State/metered``, `onLevel` hears each input level in `0...1`, about 12 a second.
    public func watch(_ owner: AnyObject, onLevel: ((Float) -> Void)? = nil, onChange: @escaping (State) -> Void) {
        let first = watchers.isEmpty
        watchers[ObjectIdentifier(owner)] = Watcher(onChange: onChange, onLevel: onLevel)
        if first { start() }
        onChange(state)
    }

    /// `owner` no longer watches; the last one out removes every listener.
    public func unwatch(_ owner: AnyObject) {
        guard watchers.removeValue(forKey: ObjectIdentifier(owner)) != nil, watchers.isEmpty else { return }
        stop()
    }

    private func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.followDevices() }
        }
        var address = Self.address(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, systemBlock) == noErr { self.systemBlock = systemBlock }
        let defaultInputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.defaultInputChanged() }
        }
        var input = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        if AudioObjectAddPropertyListenerBlock(system, &input, .main, defaultInputBlock) == noErr { self.defaultInputBlock = defaultInputBlock }
        if #available(macOS 14.2, *) {
            let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.processesChanged() }
            }
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            if AudioObjectAddPropertyListenerBlock(system, &list, .main, processBlock) == noErr { self.processBlock = processBlock }
            followProcesses()
        }
        claims.observe(self) { [weak self] in self?.refresh() }
        followDevices()
    }

    private func stop() {
        settle.cancel()
        claims.unobserve(self)
        stopMeter()
        meterEnded = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let systemBlock {
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, systemBlock)
        }
        if let processBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, processBlock)
        }
        if let defaultInputBlock {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, defaultInputBlock)
        }
        for device in Array(devices.keys) { unlisten(device) }
        for process in Array(processes.keys) { unlistenProcess(process) }
        (systemBlock, processBlock, defaultInputBlock) = (nil, nil, nil)
        state = .idle
    }

    /// A device came or went (or watching began): listen to each input device there is now.
    private func followDevices() {
        // A device change queued just before the last unwatch adds no listener back.
        guard !watchers.isEmpty else { return }
        let inputs = Set(Self.inputDevices())
        for gone in Array(devices.keys) where !inputs.contains(gone) { unlisten(gone) }
        for device in inputs where devices[device] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { devices[device] = block }
        }
        refresh()
    }

    private func unlisten(_ device: AudioObjectID) {
        guard let block = devices.removeValue(forKey: device) else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
    }

    /// Listens to each other process's input (the list changed, or watching began).
    @available(macOS 14.2, *)
    private func followProcesses() {
        guard !watchers.isEmpty else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let others = Set(Self.processObjects().filter { Self.value($0, kAudioProcessPropertyPID, pid_t(0)).map { $0 != own } ?? false })
        for gone in Array(processes.keys) where !others.contains(gone) { unlistenProcess(gone) }
        for process in others where processes[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(process, &address, .main, block) == noErr { processes[process] = block }
        }
    }

    private func unlistenProcess(_ process: AudioObjectID) {
        guard let block = processes.removeValue(forKey: process) else { return }
        // A process that left has no object: the removal fails harmlessly.
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(process, &address, .main, block)
    }

    private func processesChanged() {
        if #available(macOS 14.2, *) { followProcesses() }
        refresh()
        settle.schedule(after: .milliseconds(300)) { @MainActor [weak self] in self?.refresh() }
    }

    /// Reads the state, opens or closes the meter for it, and tells the watchers when it changed.
    func refresh() {
        guard !watchers.isEmpty else { return }
        var next = read(Array(devices.keys))
        // The outside session is over: the next one may meter again.
        if !next.active { meterEnded = false }
        next.metered = meters(next)
        guard next != state else { return }
        state = next
        for watcher in watchers.values { watcher.onChange(next) }
    }

    // MARK: The meter

    /// Opens or closes the meter for `next` and says whether it runs. The permission is read last,
    /// and only read.
    private func meters(_ next: State) -> Bool {
        let wanted = next.active && tellsProcessesApart && !meterEnded && !claims.isHeld && isAuthorized()
        if wanted, levelMeter == nil { startMeter() } else if !wanted { stopMeter() }
        return levelMeter != nil
    }

    private func startMeter() {
        // No recording: the meter folds each buffer into a level and keeps nothing.
        let meter = DictationAudioLevelMeter(recording: nil)
        levelMeter = meter
        openMeter(meter)
        levelForwarding = Task { @MainActor [weak self] in
            for await level in meter.levels { self?.forward(level, from: meter) }
            self?.meterFinished(meter)
        }
    }

    private func stopMeter() {
        guard let meter = levelMeter else { return }
        levelMeter = nil
        // Ends the forwarding at once: a level the tap still makes goes nowhere.
        meter.finish()
        levelForwarding?.cancel()
        levelForwarding = nil
        closeMeter()
    }

    /// The default input changed: the open tap's device and format are stale, so it closes and the
    /// refresh opens a new one on the new device.
    func defaultInputChanged() {
        guard levelMeter != nil else { return }
        stopMeter()
        refresh()
    }

    /// Only the running meter's levels reach the watchers: a level still queued from a closed
    /// meter's stream is dropped, even once a new meter runs.
    private func forward(_ level: Float, from meter: DictationAudioLevelMeter) {
        guard levelMeter === meter else { return }
        for watcher in watchers.values { watcher.onLevel?(level) }
    }

    /// The meter's stream ended. Unless this side closed it, the tap closed on its own: no meter
    /// for the rest of this outside session.
    private func meterFinished(_ meter: DictationAudioLevelMeter) {
        guard levelMeter === meter else { return }
        meterEnded = true
        stopMeter()
        refresh()
    }

    // MARK: CoreAudio reads

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The devices with at least one input stream.
    static func inputDevices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var all = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &all) == noErr else { return [] }
        return all.filter { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr && bytes > 0
        }
    }

    /// The state as CoreAudio has it now: on 14.2 and later, from the processes whose input runs
    /// (cmux's own left out), on any device; before, from whether any input device runs.
    static func readState(devices: [AudioObjectID]) -> State {
        if #available(macOS 14.2, *) { return processState() }
        let running = devices.contains { value($0, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)).map { $0 != 0 } ?? false }
        // Before 14.2 a running device names no process: while cmux's own dictation holds the
        // microphone, the input may be cmux's, so nothing is shown rather than a false outside mark.
        return running && !DictationMicrophoneClaims.shared.isHeld ? State(active: true, bundleId: nil, name: nil) : .idle
    }

    /// The audio process objects there are now.
    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes
    }

    @available(macOS 14.2, *)
    private static func processState() -> State {
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processObjects() {
            guard value(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                  let pid = value(process, kAudioProcessPropertyPID, pid_t(0)), pid != own else { continue }
            // The app by its pid: no CFString property read whose ownership could be got wrong.
            let app = NSRunningApplication(processIdentifier: pid)
            return State(active: true, bundleId: app?.bundleIdentifier, name: app?.localizedName)
        }
        return .idle
    }
}
