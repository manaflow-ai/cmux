#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation
internal import CmuxNextSettings

/// `debug.simulate.wake {phase}` and `debug.simulate.display` (Debug and bench builds): the system's own sleep,
/// wake and display-change notices, posted on the centers the app observes them on and in the order macOS posts
/// them, so every subscriber runs as on a real lid close or display change while the fleet Mac stays awake and
/// keeps its displays (scripts/cmux-next/lifecycle-sweep.py, p02-threads 307, RUN-12).
///
/// - `debug.simulate.wake {phase: "sleep"}` posts ``Notices/sleep`` (macOS: `NSWorkspace.willSleepNotification`,
///   then `screensDidSleepNotification`); `{phase: "wake"}` posts ``Notices/wake`` (`didWakeNotification`, then
///   `screensDidWakeNotification`), both on the workspace center from the workspace. The sweep sends `sleep`, lets
///   the app settle, then `wake`.
/// - `debug.simulate.display` posts ``Notices/display`` (`NSApplication.didChangeScreenParametersNotification`)
///   on the app center from the app, as a display added, removed or rearranged does.
///
/// The composition root passes AppKit's names and centers; this module stays free of AppKit. Chromium tests its
/// sleep and wake observers the same way: `base::test::ScopedPowerMonitorTestSource` (base/test/power_monitor_test.h)
/// calls `Suspend()` and `Resume()` on the observers the Mac source (base/power_monitor/power_monitor_device_source_mac.mm)
/// feeds from these NSWorkspace notices.
///
/// The reply names the notices posted and the main-thread time their observers took (`observers_ms`). Posting is
/// all the method does: the work it starts is the observers' own, which the sweep reads from `debug.blocking` and
/// `debug.hangs`.
@MainActor
public final class LifecycleSimulationControl {
    /// The control socket's JSON.
    typealias JSONValue = CmuxNextSettings.JSONValue

    /// The notices each simulated event posts, in the order macOS posts them.
    public struct Notices: Sendable {
        public var sleep: [Notification.Name]
        public var wake: [Notification.Name]
        public var display: Notification.Name

        public init(sleep: [Notification.Name], wake: [Notification.Name], display: Notification.Name) {
            self.sleep = sleep
            self.wake = wake
            self.display = display
        }
    }

    private let notices: Notices
    private let workspaceCenter: NotificationCenter
    private let workspace: AnyObject?
    private let appCenter: NotificationCenter
    private let application: AnyObject?

    /// - Parameters:
    ///   - notices: What each event posts (the app's: AppKit's names).
    ///   - workspaceCenter: Where macOS posts the sleep and wake notices (the app's: `NSWorkspace.shared.notificationCenter`).
    ///   - workspace: Their sender (the app's: `NSWorkspace.shared`).
    ///   - appCenter: Where AppKit posts the display notice (the app's: `NotificationCenter.default`).
    ///   - application: Its sender (the app's: `NSApp`).
    public init(notices: Notices, workspaceCenter: NotificationCenter, workspace: AnyObject?, appCenter: NotificationCenter,
                application: AnyObject?) {
        self.notices = notices
        self.workspaceCenter = workspaceCenter
        self.workspace = workspace
        self.appCenter = appCenter
        self.application = application
    }

    /// The two control methods.
    public var methods: [ControlMethod] {
        [
            .mainActor("debug.simulate.wake") { [self] call in .value(try wake(phase: call.params["phase"]?.stringValue)) },
            .mainActor("debug.simulate.display") { [self] _ in .value(display()) },
        ]
    }

    /// Posts the phase's notices; `phase` must be `sleep` or `wake`.
    func wake(phase: String?) throws(ControlError) -> JSONValue {
        let posted: [Notification.Name]
        switch phase {
        case "sleep": posted = notices.sleep
        case "wake": posted = notices.wake
        default:
            throw ControlError.invalidParams("debug.simulate.wake: phase must be \"sleep\" or \"wake\" (got \(phase ?? "none"))")
        }
        return post(posted, on: workspaceCenter, from: workspace, extra: ["phase": .string(phase ?? "")])
    }

    /// Posts the display notice.
    func display() -> JSONValue {
        post([notices.display], on: appCenter, from: application, extra: [:])
    }

    private func post(_ names: [Notification.Name], on center: NotificationCenter, from sender: AnyObject?,
                      extra: [String: JSONValue]) -> JSONValue {
        let clock = ContinuousClock()
        let start = clock.now
        for name in names {
            center.post(name: name, object: sender)
        }
        var reply = extra
        reply["posted"] = .array(names.map { .string($0.rawValue) })
        reply["observers_ms"] = .number(Double((clock.now - start) / .microseconds(1)) / 1000)
        reply["synthetic"] = .bool(true)
        return .object(reply)
    }
}
#endif
