import AppKit
import Foundation
import Testing
@testable import CmuxWorkspaces

/// Behavior tests for ``SessionLifecycleObserver``: each observed `NSWorkspace`
/// notification yields its matching ``SessionLifecycleEvent``, in arrival order,
/// and installation is once-only. A scoped `NotificationCenter` stands in for
/// `NSWorkspace.shared.notificationCenter` so the test drives the same
/// notification names the legacy observers registered for without touching the
/// process-wide workspace center.
///
/// The observers register with `queue: .main` exactly as the legacy
/// `AppDelegate` observers did, so a posted notification's `yield` runs as a
/// later main-queue operation. The tests start a child task that collects a
/// known number of events, post the notifications, then await the child with a
/// bounded timeout; the cooperative runtime drains the main-queue operations
/// while the child awaits.
@MainActor
@Suite struct SessionLifecycleObserverTests {
    @Test func yieldsOneEventPerNotificationInOrder() async throws {
        let center = NotificationCenter()
        let observer = SessionLifecycleObserver(center: center)
        observer.installIfNeeded()

        let collector = collectTask(count: 3, from: observer)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        let received = try await value(of: collector, timeout: .seconds(2))
        #expect(received == [.willPowerOff, .sessionDidResignActive, .didWake])
    }

    @Test func installIsIdempotent() async throws {
        let center = NotificationCenter()
        let observer = SessionLifecycleObserver(center: center)
        observer.installIfNeeded()
        // A second install must not register a second set of observers; a single
        // post should therefore yield exactly one event, not two.
        observer.installIfNeeded()

        let collector = collectTask(count: 1, from: observer)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        let received = try await value(of: collector, timeout: .seconds(2))
        #expect(received == [.didWake])
    }

    @Test func stopFinishesTheStream() async throws {
        let center = NotificationCenter()
        let observer = SessionLifecycleObserver(center: center)
        observer.installIfNeeded()

        // Collect to completion (nil count = until the stream finishes).
        let collector = Task { @MainActor () -> [SessionLifecycleEvent] in
            var received: [SessionLifecycleEvent] = []
            for await event in observer.events {
                received.append(event)
            }
            return received
        }
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        // Let the queued yield run, then finish the stream so the drain ends.
        try await Task.sleep(for: .milliseconds(50))
        observer.stop()

        let received = try await value(of: collector, timeout: .seconds(2))
        #expect(received == [.willPowerOff])
    }

    /// A child task that collects exactly `count` events from the stream and
    /// returns, so the awaiting test does not hang on an unfinished stream.
    private func collectTask(
        count: Int,
        from observer: SessionLifecycleObserver
    ) -> Task<[SessionLifecycleEvent], Never> {
        Task { @MainActor () -> [SessionLifecycleEvent] in
            var received: [SessionLifecycleEvent] = []
            for await event in observer.events {
                received.append(event)
                if received.count == count { break }
            }
            return received
        }
    }

    /// Awaits the collector with a deadline so a missing event fails the test
    /// instead of hanging the suite.
    private func value(
        of task: Task<[SessionLifecycleEvent], Never>,
        timeout: Duration
    ) async throws -> [SessionLifecycleEvent] {
        try await withThrowingTaskGroup(of: [SessionLifecycleEvent]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result {
                    return result
                }
                task.cancel()
                throw CancellationError()
            }
            return []
        }
    }
}
