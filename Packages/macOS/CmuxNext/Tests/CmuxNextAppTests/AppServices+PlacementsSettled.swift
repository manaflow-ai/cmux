@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
@testable import CmuxNextSidebar
import Foundation
import Testing

extension AppServices {
    /// Waits until every sidebar placement asked for so far has landed, and records an issue naming
    /// what is still in flight if that takes longer than `timeout` (a hang guard, not a quiet window):
    /// - the personal placement queue is through (#26153);
    /// - the sidebar document has the reply to every move and adopt it sent, and no load runs
    ///   (`SidebarDocStore.isSettled`; a classic import's slot moves go there, not the queue);
    /// - the store applied every daemon event sent before both were (their echoes, the personal
    ///   rows the document's write-back changed);
    /// - no live workspace still waits for its new-workspace placement;
    /// - the document projection the sidebar draws is the current one (`shownVersion == version`).
    /// A live-daemon test reads order and groups only after this. Each part is a completion signal
    /// the app itself sets; the loop repeats because applying an event can start another placement.
    @MainActor func placementsSettled(timeout: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while let unsettled = await placementsInFlight(until: deadline) {
            guard clock.now < deadline else {
                Issue.record("sidebar placements still in flight after \(timeout): \(unsettled)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    /// One pass: waits for each signal in turn (polling only its condition, up to `deadline`), then
    /// returns nil when all of them hold at once, else the first one that no longer holds.
    @MainActor private func placementsInFlight(until deadline: ContinuousClock.Instant) async -> String? {
        let clock = ContinuousClock()
        let document = SidebarDocStore.current
        func wait(_ done: () -> Bool) async {
            while !done(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        await wait { personalPlacements.isIdle }
        // The document's own completion signal (each reply resumes it), not a poll; the deadline is a hang guard only.
        if let document {
            let settled = await Self.settled(document, before: deadline)
            if !settled { return document.pendingDescription }
        }
        // Taken after the replies: every echo and write-back event of the changes above is before it.
        if let barrier = await daemon.connection?.eventSequence() {
            await wait { daemon.store.appliedSequence >= barrier }
            if daemon.store.appliedSequence < barrier { return "daemon events up to \(barrier) (applied \(daemon.store.appliedSequence))" }
        }
        await wait { awaitingPlacement().isEmpty }
        await wait { document.map { !$0.isActive || $0.shownVersion == $0.version } ?? true }
        if !personalPlacements.isIdle { return "a personal placement queued or running" }
        if let document, !document.isSettled { return document.pendingDescription }
        // Not the barrier again: a later event (a shell's output) is no placement's, and new placement
        // work since would show in the queue or the document above.
        let awaiting = awaitingPlacement()
        if !awaiting.isEmpty { return "the new-workspace placement of \(awaiting.sorted())" }
        if let document, document.isActive, document.shownVersion != document.version {
            return "the sidebar projection (shown \(document.shownVersion), document \(document.version))"
        }
        return nil
    }

    /// Whether `document` settled (``SidebarDocStore/settled()``, event-driven) before `deadline`; false
    /// leaves the wait behind so the caller can report what is pending instead of hanging past the test's limit.
    @MainActor private static func settled(_ document: SidebarDocStore, before deadline: ContinuousClock.Instant) async -> Bool {
        if document.isSettled { return true }
        @MainActor final class First {
            var continuation: CheckedContinuation<Bool, Never>?
            func resolve(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let first = First()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            // task-owner: the hang guard of one test wait; cancelled once the store settles
            let guardTask = Task { @MainActor in
                try? await Task.sleep(until: deadline)
                if !Task.isCancelled { first.resolve(false) }
            }
            // task-owner: one test wait; ends with the store's settle, or stays behind it after the hang guard
            Task { @MainActor in
                await document.settled()
                guardTask.cancel()
                first.resolve(true)
            }
        }
    }

    /// Live workspaces whose new-workspace placement has not run yet (one for a workspace that never
    /// became live, a create that failed, is not waited for).
    @MainActor private func awaitingPlacement() -> [String] {
        windows.pendingPlacementOrder.filter { machines.workspace(id: $0) != nil && windows.pendingPlacements[$0] != nil }
    }
}
