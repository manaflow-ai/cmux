public import CoreGraphics
public import Foundation
import IOSurface

/// The real ``SimulatorHIDSending`` and the source of live simulator screens:
/// SimulatorKit loaded from the active Xcode, in the app process. One input
/// transport per booted simulator, opened on first use.
///
/// In-process on purpose (plans/cmux-next/simulators-DESIGN.md): every private
/// call is checked with `respondsToSelector:` first, so a changed Xcode turns
/// the live screen off (the tab falls back to `simctl` still frames) instead
/// of crashing. Classic cmux's worker process, pipe protocol and supervision
/// cost far more than they protected.
@MainActor
public final class SimulatorKitHID: SimulatorHIDSending {
    private let runtime: SimulatorKitRuntime
    private let clock: any Clock<Duration>
    private var transports: [String: SimulatorHIDTransport] = [:]
    private var screens: [String: SimulatorScreenSource] = [:]
    /// Who watches each simulator's frames (the Mac's phone tab, a phone streaming it).
    private var watchers: [String: [UUID: @MainActor (IOSurface) -> Void]] = [:]

    /// - Parameters:
    ///   - developerDirectory: the active Xcode's Developer folder (`xcode-select -p`).
    ///   - clock: paces touch events; tests pass a virtual clock.
    public init(developerDirectory: String, clock: any Clock<Duration> = ContinuousClock()) {
        runtime = SimulatorKitRuntime(developerDirectory: developerDirectory)
        self.clock = clock
    }

    /// The selected Xcode's Developer folder without running a process: `DEVELOPER_DIR`, else the
    /// link `xcode-select -s` writes, else the App Store Xcode.
    public nonisolated static func selectedDeveloperDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
        if let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"), !linked.isEmpty {
            return linked
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    /// Whether this Xcode's SimulatorKit loads (live screens and input work).
    public func isAvailable() -> Bool {
        (try? runtime.load()) != nil
    }

    // MARK: SimulatorHIDSending (nonisolated witnesses that run on the main actor)

    public nonisolated func screenSize(of udid: String) async throws -> CGSize { try await mainScreenSize(udid) }
    public nonisolated func send(touches: [PhoneTouch], to udid: String) async throws { try await mainSend(touches: touches, udid) }
    public nonisolated func send(keys: [PhoneKeyStroke], to udid: String) async throws { try await mainSend(keys: keys, udid) }
    public nonisolated func press(page: UInt32, usage: UInt32, on udid: String) async throws {
        try await mainPress(page: page, usage: usage, udid)
    }
    public nonisolated func toggleSoftwareKeyboard(on udid: String) async throws { try await mainToggleSoftwareKeyboard(udid) }

    private func mainToggleSoftwareKeyboard(_ udid: String) throws {
        try transport(udid).toggleSoftwareKeyboard()
    }

    private func mainScreenSize(_ udid: String) throws -> CGSize {
        let device = try runtime.device(udid)
        let scale = privateObject(device, "deviceType").flatMap { privateNumber($0, "mainScreenScale") } ?? 0
        // The live surface is in the displayed orientation; the device type's size is portrait only.
        if let surface = screens[udid]?.surface, scale > 0 {
            return CGSize(width: Double(IOSurfaceGetWidth(surface)) / scale, height: Double(IOSurfaceGetHeight(surface)) / scale)
        }
        guard scale > 0, let pixels = privateObject(device, "deviceType").flatMap({ privateSize($0, "mainScreenSize") }) else {
            throw PhoneError.unreadable(what: "the simulator's screen size")
        }
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    private func mainSend(touches: [PhoneTouch], _ udid: String) async throws {
        let transport = try transport(udid)
        var previous = Duration.zero
        for touch in touches {
            if touch.offset > previous {
                // concurrency-allow: a bounded, intended delay that paces a gesture's events at their planned offsets (injected clock).
                // wakeup-allow: runs only during a gesture an agent or person asked for, never while idle.
                try await clock.sleep(for: touch.offset - previous, tolerance: nil)
                previous = touch.offset
            }
            try transport.touch(touch.phase, x: touch.x, y: touch.y)
        }
    }

    private func mainSend(keys: [PhoneKeyStroke], _ udid: String) async throws {
        let transport = try transport(udid)
        for stroke in keys {
            if stroke.command { try transport.key(0xE3, down: true) }
            if stroke.shift { try transport.key(0xE1, down: true) }
            try transport.key(stroke.usage, down: true)
            try transport.key(stroke.usage, down: false)
            if stroke.shift { try transport.key(0xE1, down: false) }
            if stroke.command { try transport.key(0xE3, down: false) }
            // concurrency-allow: a bounded, intended 8 ms gap so the guest's key repeat logic sees separate presses (injected clock).
            // wakeup-allow: runs only while typing text that was asked for, never while idle.
            try await clock.sleep(for: .milliseconds(8), tolerance: nil)
        }
    }

    private func mainPress(page: UInt32, usage: UInt32, _ udid: String) async throws {
        let transport = try transport(udid)
        try transport.button(page: page, usage: usage, down: true)
        // concurrency-allow: a bounded, intended hold; Siri needs a long press, other buttons a short one (injected clock).
        // wakeup-allow: runs only during a button press that was asked for, never while idle.
        try await clock.sleep(for: usage == 0xCF ? .milliseconds(300) : .milliseconds(60), tolerance: nil)
        try transport.button(page: page, usage: usage, down: false)
    }

    // MARK: Live screens and view input

    /// One watcher of a simulator's frames; ``stopScreen(_:)`` ends it.
    public struct ScreenWatch: Hashable, Sendable {
        let udid: String
        let id: UUID
    }

    /// Starts frames for `udid` and hands each one to `onFrame`, beside any other
    /// watcher of the same simulator (the Mac's tab and a phone stream it at once).
    /// Call ``stopScreen(_:)`` when the watcher is done: the last one stops the callbacks.
    func startScreen(_ udid: String, onFrame: @escaping @MainActor (IOSurface) -> Void) throws -> ScreenWatch {
        let watch = ScreenWatch(udid: udid, id: UUID())
        if let source = screens[udid] {
            watchers[udid, default: [:]][watch.id] = onFrame
            if let surface = source.surface { onFrame(surface) }
            return watch
        }
        let source = try SimulatorScreenSource(device: runtime.device(udid))
        source.onFrame = { [weak self] surface in
            for watcher in self?.watchers[udid]?.values.map({ $0 }) ?? [] { watcher(surface) }
        }
        watchers[udid] = [watch.id: onFrame]
        screens[udid] = source
        do {
            try source.start()
        } catch {
            screens[udid] = nil
            watchers[udid] = nil
            throw error
        }
        return watch
    }

    /// Ends `watch`; with no watcher left no frame work happens until one starts.
    func stopScreen(_ watch: ScreenWatch) {
        watchers[watch.udid]?[watch.id] = nil
        guard watchers[watch.udid]?.isEmpty ?? true else { return }
        watchers[watch.udid] = nil
        screens.removeValue(forKey: watch.udid)?.stop()
    }

    /// The simulator's screen now (nil while nobody watches it).
    func currentSurface(_ udid: String) -> IOSurface? {
        screens[udid]?.surface
    }

    /// Sends one touch at once (the tab's mouse events, already paced by the person).
    func touchNow(_ phase: PhoneTouch.Phase, x: Double, y: Double, udid: String) throws {
        try transport(udid).touch(phase, x: x, y: y)
    }

    /// Sends one key change at once (the tab's key events).
    func keyNow(_ usage: UInt32, down: Bool, udid: String) throws {
        try transport(udid).key(usage, down: down)
    }

    private func transport(_ udid: String) throws -> SimulatorHIDTransport {
        if let known = transports[udid] { return known }
        let made = try SimulatorHIDTransport(device: runtime.device(udid), runtime: runtime)
        transports[udid] = made
        return made
    }

    /// Drops the input transport (after a reboot the old XPC connection is dead).
    func reset(_ udid: String) {
        transports.removeValue(forKey: udid)?.close()
        watchers[udid] = nil
        screens.removeValue(forKey: udid)?.stop()
    }
}
