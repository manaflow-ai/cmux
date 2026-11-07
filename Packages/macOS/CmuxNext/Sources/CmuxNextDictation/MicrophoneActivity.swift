import AppKit
import CoreAudio

/// Whether another app is using the microphone, for the composer's outside-dictation indicator
/// (design/composer-dictation.md). It only reads CoreAudio properties: the default input device's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere`, and on macOS 14.2 and later the audio process
/// objects' `kAudioProcessPropertyIsRunningInput`, to name the app that holds it. It never opens
/// the microphone and never hears audio, so it knows whether input runs, not how loud it is.
///
/// Listeners run only while someone watches (a focused composer, ``watch(_:onChange:)``): the last
/// ``unwatch(_:)`` removes them, so no observer runs while no composer has the keyboard.
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

        public static let idle = State(active: false, bundleId: nil, name: nil)
    }

    private var watchers: [ObjectIdentifier: (State) -> Void] = [:]
    public private(set) var state = State.idle
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var processBlock: AudioObjectPropertyListenerBlock?
    /// A second read shortly after a process-list change: a process joins the list before its
    /// input starts, so the first read can miss it.
    private var settle: Task<Void, Never>?

    /// Reads the state now (tests pass their own).
    var read: @MainActor (_ device: AudioObjectID) -> State = { MicrophoneActivity.readState(device: $0) }
    /// Whether listeners are installed (tests).
    var isListening: Bool { deviceBlock != nil || systemBlock != nil }

    public init() {}

    /// `owner` wants the state: told now, then on every change, until ``unwatch(_:)``.
    public func watch(_ owner: AnyObject, onChange: @escaping (State) -> Void) {
        let first = watchers.isEmpty
        watchers[ObjectIdentifier(owner)] = onChange
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
            Task { @MainActor in self?.followDefaultDevice() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, systemBlock) == noErr { self.systemBlock = systemBlock }
        if #available(macOS 14.2, *) {
            let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.processesChanged() }
            }
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            if AudioObjectAddPropertyListenerBlock(system, &list, .main, processBlock) == noErr { self.processBlock = processBlock }
        }
        followDefaultDevice()
    }

    private func stop() {
        settle?.cancel()
        settle = nil
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let systemBlock {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, systemBlock)
        }
        if let processBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, processBlock)
        }
        unlistenDevice()
        (systemBlock, processBlock) = (nil, nil)
        state = .idle
    }

    /// The default input device changed (or watching began): listen to the new one.
    private func followDefaultDevice() {
        let next = Self.defaultInputDevice()
        if next != device {
            unlistenDevice()
            device = next
            if next != kAudioObjectUnknown {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                }
                var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                if AudioObjectAddPropertyListenerBlock(next, &address, .main, block) == noErr { deviceBlock = block }
            }
        }
        refresh()
    }

    private func unlistenDevice() {
        if let deviceBlock, device != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceBlock)
        }
        deviceBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func processesChanged() {
        refresh()
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Reads the state and tells the watchers when it changed.
    func refresh() {
        guard !watchers.isEmpty else { return }
        let next = read(device)
        guard next != state else { return }
        state = next
        for watcher in watchers.values { watcher(next) }
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

    static func defaultInputDevice() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// The state as CoreAudio has it now: on 14.2 and later, from the processes whose input runs
    /// (cmux's own left out); before, from the device alone.
    static func readState(device: AudioObjectID) -> State {
        if #available(macOS 14.2, *) { return processState() }
        guard device != kAudioObjectUnknown,
              let running = value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) else { return .idle }
        return State(active: running != 0, bundleId: nil, name: nil)
    }

    @available(macOS 14.2, *)
    private static func processState() -> State {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return .idle }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return .idle }
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            guard value(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                  let pid = value(process, kAudioProcessPropertyPID, pid_t(0)), pid != own else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return State(active: true, bundleId: bundleId(of: process) ?? app?.bundleIdentifier, name: app?.localizedName)
        }
        return .idle
    }

    @available(macOS 14.2, *)
    private static func bundleId(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &name) == noErr,
              let text = name?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
        return text
    }
}
