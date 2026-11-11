import AppKit
import AVFoundation
import CmuxNextCompat
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

    /// What the source tells the main actor.
    enum SourceEvent: Sendable {
        /// The state as CoreAudio has it now. `namesProcesses`: it came from the process objects
        /// (14.2 and later), so cmux's own input is already left out.
        case read(State, namesProcesses: Bool)
        /// The default input changed: a running meter moves to the new device.
        case defaultInputChanged
        /// The process list changed: a process joins it before its input starts, so read again
        /// shortly after.
        case processesChanged
    }

    private var watchers: [ObjectIdentifier: Watcher] = [:]
    public private(set) var state = State.idle
    /// Where the state comes from: CoreAudio on its own queue in the app (``CoreAudioMicrophoneSource``),
    /// a fake in tests. Every CoreAudio property call is a synchronous message to the audio server,
    /// so none of them runs on the main thread.
    private let source: any MicrophoneActivitySource
    /// The last reading, applied again when only cmux's side changed (a claim, a closed meter).
    private var reading: (state: State, namesProcesses: Bool)?
    /// A second read shortly after a process-list change: a process joins the list before its
    /// input starts, so the first read can miss it.
    private let settle = DemandTimer(owner: "microphone-activity.settle")

    /// Whether listeners are installed (tests).
    var isListening: Bool { source.isListening }

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

    public convenience init(claims: DictationMicrophoneClaims = .shared) {
        self.init(claims: claims, source: CoreAudioMicrophoneSource())
    }

    init(claims: DictationMicrophoneClaims, source: any MicrophoneActivitySource) {
        self.claims = claims
        self.source = source
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
        claims.observe(self) { [weak self] in self?.claimsChanged() }
        source.start { [weak self] event in self?.receive(event) }
    }

    private func stop() {
        settle.cancel()
        claims.unobserve(self)
        source.stop()
        stopMeter()
        meterEnded = false
        reading = nil
        state = .idle
    }

    /// cmux's own dictation took or gave back the microphone. A claim hides the mark and closes the
    /// meter at once (from the last reading). A release before 14.2 waits for the fresh read: the
    /// last reading saw cmux's own input as a running device, so it would show a false outside mark.
    private func claimsChanged() {
        if claims.isHeld || reading?.namesProcesses == true { reapply() }
        refresh()
    }

    private func receive(_ event: SourceEvent) {
        // An event the source sent before the last unwatch changes nothing.
        guard !watchers.isEmpty else { return }
        switch event {
        case let .read(next, namesProcesses):
            reading = (next, namesProcesses)
            reapply()
        case .defaultInputChanged:
            defaultInputChanged()
        case .processesChanged:
            settle.schedule(after: .milliseconds(300)) { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Asks the source to read the state again; the watchers hear it when it arrives.
    func refresh() {
        guard !watchers.isEmpty else { return }
        source.requestRead()
    }

    /// Applies the last reading: opens or closes the meter for it, and tells the watchers when the
    /// state changed.
    private func reapply() {
        guard !watchers.isEmpty, let reading else { return }
        var next = reading.state
        // Before 14.2 a running device names no process: while cmux's own dictation holds the
        // microphone, the input may be cmux's, so nothing is shown rather than a false outside mark.
        if !reading.namesProcesses, claims.isHeld { next = .idle }
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
        reapply()
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
        reapply()
    }
}

/// Where ``MicrophoneActivity`` gets its state: start listening, stop, read again. The app's is
/// ``CoreAudioMicrophoneSource``; tests pass a fake that answers at once.
@MainActor
protocol MicrophoneActivitySource: AnyObject {
    /// Whether it listens (between ``start(_:)`` and ``stop()``).
    var isListening: Bool { get }
    /// Starts listening and reads once; `deliver` hears each event on the main actor until
    /// ``stop()``.
    func start(_ deliver: @escaping @MainActor (MicrophoneActivity.SourceEvent) -> Void)
    /// Stops listening; nothing is delivered after it.
    func stop()
    /// Reads the state again and delivers it.
    func requestRead()
}

/// The CoreAudio side of ``MicrophoneActivity``: every property listener and read, on one serial
/// queue of its own. Each CoreAudio property call is a synchronous message to the audio server;
/// while that server is slow one call can take seconds, and on the main thread that froze the app
/// (NIGHTLY 85b0999, 2026-11-10: main-thread hangs of 30.3 s, 6.9 s and 6.8 s in
/// `processState()`'s `AudioObjectGetPropertyData`, from a refresh a listener queued on main).
/// Here they hold only this queue; the main actor gets the result.
@MainActor
final class CoreAudioMicrophoneSource: MicrophoneActivitySource {
    private let engine: Engine
    /// Counts starts and stops: an event from an earlier start is dropped on arrival.
    private var session: UInt64 = 0
    private(set) var isListening = false

    /// `read` reads the state on the source's queue; `listens` installs the CoreAudio listeners
    /// (tests turn both off).
    init(read: @escaping @Sendable () -> (MicrophoneActivity.State, namesProcesses: Bool) = { CoreAudioMicrophoneSource.readState() },
         listens: Bool = true) {
        engine = Engine(read: read, listens: listens)
    }

    func start(_ deliver: @escaping @MainActor (MicrophoneActivity.SourceEvent) -> Void) {
        session &+= 1
        isListening = true
        let started = session
        engine.start { [weak self] event in
            MainDelivery().run {
                guard let self, self.isListening, self.session == started else { return }
                deliver(event)
            }
        }
    }

    func stop() {
        session &+= 1
        isListening = false
        engine.stop()
    }

    func requestRead() {
        guard isListening else { return }
        engine.requestRead()
    }

    /// The listeners and reads. All of its work runs on the serial `queue`, the queue CoreAudio
    /// calls the listeners on; the state sits in a `Mutex` so the compiler checks it, and the lock
    /// is never contended since only that queue takes it.
    final class Engine: Sendable {
        /// A CoreAudio listener block that captures only a weak reference to this (Sendable)
        /// engine, so the state can hold it.
        typealias ListenerBlock = @convention(block) @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

        private let queue = DispatchQueue(label: "com.cmuxterm.dictation.microphone-activity", qos: .utility)
        private let read: @Sendable () -> (MicrophoneActivity.State, namesProcesses: Bool)
        private let listens: Bool
        private let state = Mutex(Listening())

        private struct Listening {
            var deliver: (@Sendable (MicrophoneActivity.SourceEvent) -> Void)?
            /// A read is queued and not started yet: requests meanwhile join it, so a slow audio
            /// server meets at most one read running and one waiting, never a backlog of listener
            /// events.
            var readQueued = false
            /// The input devices listened to, each with its `IsRunningSomewhere` listener: every
            /// input, not only the default one, since an app may record from any of them.
            var devices: [AudioObjectID: ListenerBlock] = [:]
            var systemBlock: ListenerBlock?
            var processBlock: ListenerBlock?
            /// The default input's listener: a running meter moves to the new device.
            var defaultInputBlock: ListenerBlock?
            /// Each other process's `IsRunningInput` listener (14.2 and later): while the meter's
            /// own tap runs, the device stays running because of it, so the other app's release
            /// shows only here.
            var processes: [AudioObjectID: ListenerBlock] = [:]
        }

        init(read: @escaping @Sendable () -> (MicrophoneActivity.State, namesProcesses: Bool), listens: Bool) {
            self.read = read
            self.listens = listens
        }

        // Each entry point queues its work on `queue` in call order, so a stop stays ahead of the
        // next start.
        func start(_ deliver: @escaping @Sendable (MicrophoneActivity.SourceEvent) -> Void) {
            queue.async { [self] in
                state.withLock { $0.deliver = deliver }
                // Listening reads once (its device scan queues the read); without it, read now.
                if listens { listen() } else { readNow() }
            }
        }

        func stop() {
            queue.async { [self] in
                state.withLock { listening in
                    listening.deliver = nil
                    listening.readQueued = false
                }
                if listens { unlistenAll() }
            }
        }

        func requestRead() {
            queue.async { [self] in scheduleRead() }
        }

        /// The current deliver, while started. On `queue`.
        private var deliver: (@Sendable (MicrophoneActivity.SourceEvent) -> Void)? {
            state.withLock { $0.deliver }
        }

        /// Queues one read unless one is queued already. On `queue`.
        private func scheduleRead() {
            let queues = state.withLock { listening -> Bool in
                guard listening.deliver != nil, !listening.readQueued else { return false }
                listening.readQueued = true
                return true
            }
            guard queues else { return }
            queue.async { [self] in
                state.withLock { $0.readQueued = false }
                readNow()
            }
        }

        private func readNow() {
            guard deliver != nil else { return }
            let (next, namesProcesses) = read()
            // A stop while the read ran: nothing goes out.
            deliver?(.read(next, namesProcesses: namesProcesses))
        }

        // MARK: Listeners (on `queue`; CoreAudio calls them there)

        private func listen() {
            let system = AudioObjectID(kAudioObjectSystemObject)
            let systemBlock: ListenerBlock = { [weak self] _, _ in self?.followDevices() }
            var address = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyDevices)
            let systemAdded = AudioObjectAddPropertyListenerBlock(system, &address, queue, systemBlock) == noErr
            let defaultInputBlock: ListenerBlock = { [weak self] _, _ in self?.deliver?(.defaultInputChanged) }
            var input = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyDefaultInputDevice)
            let inputAdded = AudioObjectAddPropertyListenerBlock(system, &input, queue, defaultInputBlock) == noErr
            state.withLock { listening in
                if systemAdded { listening.systemBlock = systemBlock }
                if inputAdded { listening.defaultInputBlock = defaultInputBlock }
            }
            if #available(macOS 14.2, *) {
                let processBlock: ListenerBlock = { [weak self] _, _ in self?.processesChanged() }
                var list = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyProcessObjectList)
                if AudioObjectAddPropertyListenerBlock(system, &list, queue, processBlock) == noErr {
                    state.withLock { $0.processBlock = processBlock }
                }
                followProcesses()
            }
            followDevices()
        }

        private func unlistenAll() {
            let system = AudioObjectID(kAudioObjectSystemObject)
            let listening = state.withLock { listening -> Listening in
                let all = listening
                listening.devices = [:]
                listening.processes = [:]
                (listening.systemBlock, listening.processBlock, listening.defaultInputBlock) = (nil, nil, nil)
                return all
            }
            if let systemBlock = listening.systemBlock {
                var address = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, systemBlock)
            }
            if let processBlock = listening.processBlock {
                var address = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, processBlock)
            }
            if let defaultInputBlock = listening.defaultInputBlock {
                var address = CoreAudioMicrophoneSource.address(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, defaultInputBlock)
            }
            for (device, block) in listening.devices { unlisten(device, block) }
            for (process, block) in listening.processes { unlistenProcess(process, block) }
        }

        /// A device came or went (or listening began): listen to each input device there is now.
        private func followDevices() {
            // A device change queued just before the stop adds no listener back.
            guard deliver != nil else { return }
            let inputs = Set(CoreAudioMicrophoneSource.inputDevices())
            let (gone, known) = state.withLock { listening in
                let gone = listening.devices.filter { !inputs.contains($0.key) }
                for device in gone.keys { listening.devices[device] = nil }
                return (gone, Set(listening.devices.keys))
            }
            for (device, block) in gone { unlisten(device, block) }
            for device in inputs where !known.contains(device) {
                let block: ListenerBlock = { [weak self] _, _ in self?.scheduleRead() }
                var address = CoreAudioMicrophoneSource.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                    state.withLock { $0.devices[device] = block }
                }
            }
            scheduleRead()
        }

        private func unlisten(_ device: AudioObjectID, _ block: @escaping ListenerBlock) {
            var address = CoreAudioMicrophoneSource.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }

        /// Listens to each other process's input (the list changed, or listening began).
        @available(macOS 14.2, *)
        private func followProcesses() {
            guard deliver != nil else { return }
            let own = ProcessInfo.processInfo.processIdentifier
            let others = Set(CoreAudioMicrophoneSource.processObjects().filter {
                CoreAudioMicrophoneSource.value($0, kAudioProcessPropertyPID, pid_t(0)).map { $0 != own } ?? false
            })
            let (gone, known) = state.withLock { listening in
                let gone = listening.processes.filter { !others.contains($0.key) }
                for process in gone.keys { listening.processes[process] = nil }
                return (gone, Set(listening.processes.keys))
            }
            for (process, block) in gone { unlistenProcess(process, block) }
            for process in others where !known.contains(process) {
                let block: ListenerBlock = { [weak self] _, _ in self?.scheduleRead() }
                var address = CoreAudioMicrophoneSource.address(kAudioProcessPropertyIsRunningInput)
                if AudioObjectAddPropertyListenerBlock(process, &address, queue, block) == noErr {
                    state.withLock { $0.processes[process] = block }
                }
            }
        }

        private func unlistenProcess(_ process: AudioObjectID, _ block: @escaping ListenerBlock) {
            // A process that left has no object: the removal fails harmlessly.
            var address = CoreAudioMicrophoneSource.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
        }

        private func processesChanged() {
            guard deliver != nil else { return }
            if #available(macOS 14.2, *) { followProcesses() }
            scheduleRead()
            deliver?(.processesChanged)
        }
    }

    // MARK: CoreAudio reads (off the main thread only)

    nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The devices with at least one input stream.
    nonisolated static func inputDevices() -> [AudioObjectID] {
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
    /// (cmux's own left out), on any device; before, from whether any input device runs (the main
    /// actor then leaves it out while cmux's own dictation holds the microphone).
    nonisolated static func readState() -> (MicrophoneActivity.State, namesProcesses: Bool) {
        if #available(macOS 14.2, *) { return (processState(), true) }
        let running = inputDevices().contains { value($0, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)).map { $0 != 0 } ?? false }
        return (running ? MicrophoneActivity.State(active: true, bundleId: nil, name: nil) : .idle, false)
    }

    /// The audio process objects there are now.
    @available(macOS 14.2, *)
    nonisolated static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes
    }

    @available(macOS 14.2, *)
    nonisolated private static func processState() -> MicrophoneActivity.State {
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processObjects() {
            guard value(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                  let pid = value(process, kAudioProcessPropertyPID, pid_t(0)), pid != own else { continue }
            // The app by its pid: no CFString property read whose ownership could be got wrong.
            // NSRunningApplication's properties are thread safe.
            let app = NSRunningApplication(processIdentifier: pid)
            return MicrophoneActivity.State(active: true, bundleId: app?.bundleIdentifier, name: app?.localizedName)
        }
        return .idle
    }
}
