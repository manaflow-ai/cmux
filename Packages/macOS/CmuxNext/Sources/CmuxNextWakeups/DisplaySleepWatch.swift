import AppKit

/// Whether the Mac's displays sleep, for the app's visibility node, the occlusion checker and the
/// energy watch: it follows the displays' real state, not a pairing of notices.
///
/// `NSWorkspace.screensDidSleepNotification` comes when the displays go dark and
/// `screensDidWakeNotification` when they light again, but a wake can come with no screens notice:
/// a system sleep that starts while the displays sleep wakes with only
/// `NSWorkspace.didWakeNotification`, and a display plugged in or out while they sleep posts only
/// `NSApplication.didChangeScreenParametersNotification`. A flag that only the screens-wake notice
/// clears then says "asleep" until the next display wake. So each screens notice sets the state it
/// announces (a read of the displays on the same turn may lag it), and a system wake or a display
/// change reads the displays again through the probe (``everyDisplayAsleep()`` in the app, Core
/// Graphics as `DisplaySleep` reads it for motion). The probe also gives the state at creation, so
/// an owner made while the displays sleep starts asleep. A probe that cannot tell (no display
/// online) changes nothing. The composition root injects the probe; tests pass their own. Chrome likewise reads the state again when it may have
/// changed instead of pairing notices: its screen re-queries the displays on each reconfiguration
/// (ui/display/mac/screen_mac.mm) and its power monitor reads the power state on resume
/// (base/power_monitor).
///
/// Each owner makes one from the app's events it already follows, and drops it with ``cancel()``:
///
/// ```swift
/// displays = DisplaySleepWatch(workspaceEvents: workspaceEvents, appEvents: appEvents, owner: "Owner", probe: displaysAsleep)
/// displays.onChange = { [weak self] asleep in self?.setAsleep(asleep) }
/// ```
@MainActor public final class DisplaySleepWatch {
    /// Whether every display sleeps now; nil when it cannot tell (no display online). Read on a
    /// notice, never per frame.
    public typealias Probe = @MainActor () -> Bool?

    /// The displays sleep.
    public private(set) var asleep: Bool
    /// Called with ``asleep`` after each change (not for the state at creation).
    public var onChange: (@MainActor (Bool) -> Void)?

    private let probe: Probe
    /// The notices it follows; kept here, as a subscription holds its fan-out only weakly.
    private let workspaceEvents: AppEvents
    private let appEvents: AppEvents
    private var subscriptions: [EventSubscription] = []

    /// Reads the displays once and follows the notices that may change them.
    ///
    /// - Parameters:
    ///   - workspaceEvents: The fan-out on `NSWorkspace.shared.notificationCenter` (the screens' sleep
    ///     and wake, the system's wake).
    ///   - appEvents: The fan-out on the center of `NSApplication.didChangeScreenParametersNotification`
    ///     (`NotificationCenter.default` in the app).
    ///   - owner: The subscriber's name for diagnostics.
    ///   - probe: Whether every display sleeps now (``everyDisplayAsleep()`` in the app; tests pass
    ///     their own). Nil at creation counts as awake: nothing says the displays went dark.
    public init(workspaceEvents: AppEvents, appEvents: AppEvents, owner: String, probe: @escaping Probe) {
        self.probe = probe
        self.workspaceEvents = workspaceEvents
        self.appEvents = appEvents
        asleep = probe() ?? false
        subscriptions = [
            workspaceEvents.subscribe(NSWorkspace.screensDidSleepNotification, owner: owner) { [weak self] in self?.set(true) },
            workspaceEvents.subscribe(NSWorkspace.screensDidWakeNotification, owner: owner) { [weak self] in self?.set(false) },
            workspaceEvents.subscribe(NSWorkspace.didWakeNotification, owner: owner) { [weak self] in self?.readDisplays() },
            appEvents.subscribe(NSApplication.didChangeScreenParametersNotification, owner: owner) { [weak self] in self?.readDisplays() },
        ]
    }

    /// Stops following the notices; ``asleep`` stays as it was.
    public func cancel() {
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
    }

    /// Core Graphics' answer: every online display sleeps (`CGDisplayIsAsleep`). An asleep display
    /// is online but not active, so the online list is the one to read. Nil when no display is
    /// online or the list cannot be read: a Mac mini whose only monitor dropped off the bus in
    /// standby, or a headless Mac, says nothing about a wake.
    nonisolated public static func everyDisplayAsleep() -> Bool? {
        var count: UInt32 = 0
        // SAFETY: with a null list CGGetOnlineDisplayList writes only the count, into a local live for the call.
        guard unsafe CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        let capacity = Int(count)
        guard capacity > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: capacity)
        // SAFETY: CGGetOnlineDisplayList writes at most `displays.count` IDs into the array's storage and the
        // count into a local, both live for the call.
        guard unsafe CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        let online = displays.prefix(Int(count))
        guard !online.isEmpty else { return nil }
        return online.allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// A system wake or a display change: the displays' state now, unless the probe cannot tell.
    private func readDisplays() {
        guard let value = probe() else { return }
        set(value)
    }

    private func set(_ value: Bool) {
        guard value != asleep else { return }
        asleep = value
        onChange?(value)
    }
}
