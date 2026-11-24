import Foundation
@testable import CmuxNextNotifications
import Testing
import UserNotifications

/// The banners never wait on the notification daemon on the main thread: a `usernoted` that does not answer
/// froze the whole app for minutes when a viewed tab withdrew its banner
/// (https://github.com/manaflow-ai/cmux/issues/47009).
@MainActor
struct DesktopNotifierOffMainTests {
    @Test func aStalledNotificationDaemonNeverHoldsTheMainThread() async {
        let daemon = StalledNotificationDaemon()
        let notifier = DesktopNotifier(backend: daemon)
        notifier.post(id: "cmux-notification-1", title: "Done", body: "Build finished", surface: nil, workspace: nil, defaultSound: false)
        // The tab was viewed: its banner goes, while the daemon still has not answered anything.
        notifier.withdraw(["cmux-notification-1"])
        notifier.post(id: "cmux-notification-2", title: "Done", body: "Tests passed", surface: nil, workspace: nil, defaultSound: false)
        // Back on the main actor before the daemon answered: it never waited for the daemon.
        daemon.answer()
        await notifier.centerCallsDrained()

        let calls = daemon.calls()
        #expect(!daemon.timedOut, "a center call waited on the stalled daemon on the main thread")
        #expect(calls.allSatisfy { !$0.onMainThread }, "a center call ran on the main thread: \(calls)")
        // Authorization (asked unless a GUI job) and an automation launch's clearing depend on the test host.
        let banners = calls.map(\.name).filter { !$0.hasPrefix("authorization") && $0 != "withdraw all" }
        #expect(banners == ["categories", "post cmux-notification-1", "withdraw cmux-notification-1", "post cmux-notification-2"])
    }
}

/// A notification daemon that answers nothing until `answer()`: each call waits for it, at most 5 s.
private final class StalledNotificationDaemon: NotificationCenterBackend, @unchecked Sendable {
    struct Call: Sendable {
        var name: String
        var onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var stalledPastDeadline = false
    private let answered = DispatchSemaphore(value: 0)

    var timedOut: Bool { lock.withLock { stalledPastDeadline } }

    func calls() -> [Call] { lock.withLock { recorded } }

    /// The daemon answers from now on.
    func answer() {
        // One signal per waiter is enough: after the first wakes, `answer` releases the rest.
        answered.signal()
    }

    private func call(_ name: String) {
        let onMainThread = Thread.isMainThread
        let wokeInTime = answered.wait(timeout: .now() + 5) == .success
        if wokeInTime { answered.signal() }
        lock.withLock {
            if !wokeInTime { stalledPastDeadline = true }
            recorded.append(Call(name: name, onMainThread: onMainThread))
        }
    }

    func post(_ request: UNNotificationRequest, completion: @escaping @Sendable ((any Error)?) -> Void) {
        call("post \(request.identifier)")
        completion(nil)
    }

    func withdraw(_ ids: [String]) { call("withdraw " + ids.joined(separator: ",")) }

    func withdrawAll() { call("withdraw all") }

    func install(categories: Set<UNNotificationCategory>) { call("categories") }

    func askAuthorization(_ options: UNAuthorizationOptions, completion: @escaping @Sendable (Bool) -> Void) {
        call("authorization")
        completion(true)
    }

    func bannerIDs(completion: @escaping @Sendable (_ delivered: [String], _ pending: [String]) -> Void) {
        call("banner ids")
        completion([], [])
    }
}
