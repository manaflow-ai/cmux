@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// Collapsing a group is this window's look: a save whose reply is slow is sent again quietly, and only a
/// refusal undoes the fold with a notice (Leo, 2026-11-03: "Collapse/Expand Workspace Group did not apply:
/// update-personal-group: timed out: workspace_group.update (no reply within 2.0 seconds)").
@MainActor @Suite struct SidebarFoldPersistTests {
    private struct Failure: Sendable { var timedOut: Bool }
    private let group = GroupID("grp_fold")
    private let quick = Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0)

    private func edits() -> (SidebarRowEdits, SidebarModel) {
        let model = SidebarModel()
        return (SidebarRowEdits(model: model, redraw: {}, confirmedFold: { _, _ in }), model)
    }

    /// What one fold save did: the sends that went out, the refusals reported, and whether it settled through `saved`.
    @MainActor private final class Record {
        var sends = 0, refused = 0, saved = false
        var done: CheckedContinuation<Void, Never>?
        func finish() { done?.resume(); done = nil }
    }

    /// Saves one fold with `answers` as the daemon's replies in order (nil: replied). `before` runs at the first send.
    private func run(_ edits: SidebarRowEdits, _ answers: [Failure?], before: (@MainActor () -> Void)? = nil)
        async -> (sends: Int, refused: Int, saved: Bool) {
        let record = Record()
        let group = group, quick = quick
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            record.done = done
            edits.saveFold(group, collapsed: true, backoff: quick, save: {
                let index = record.sends
                record.sends += 1
                if index == 0 { before?() }
                let answer = index < answers.count ? answers[index] : nil
                // The last scripted failure (or the one a later click supersedes) ends the run.
                if answer != nil, index == answers.count - 1 || before != nil { record.finish() }
                return answer
            }, mayHaveApplied: { $0.timedOut }, refused: { _ in record.refused += 1; record.finish() },
            saved: { settle in record.saved = true; settle(); record.finish() })
        }
        // Let a retry that should not happen have its chance.
        try? await Task.sleep(for: .milliseconds(50))
        return (record.sends, record.refused, record.saved)
    }

    @Test func aSlowReplyIsSentAgainWithNoNoticeAndTheFoldStays() async {
        let (edits, model) = edits()
        let result = await run(edits, [Failure(timedOut: true), Failure(timedOut: true), nil])
        #expect(result.sends == 3)
        #expect(result.refused == 0, "a slow save must not report a failure")
        #expect(result.saved)
        _ = model
    }

    @Test func aRefusalIsReportedOnceWithNoRetry() async {
        let (edits, _) = edits()
        let result = await run(edits, [Failure(timedOut: false)])
        #expect(result.sends == 1)
        #expect(result.refused == 1)
        #expect(!edits.holdsFold(group, collapsed: true), "a refusal drops the fold")
    }

    @Test func aSaveThatNeverAnswersGivesUpQuietly() async {
        let (edits, _) = edits()
        let timeouts = Array(repeating: Failure?.some(Failure(timedOut: true)), count: SidebarFoldPersist.retries + 1)
        let result = await run(edits, timeouts)
        #expect(result.sends == SidebarFoldPersist.retries + 1)
        #expect(result.refused == 0)
        #expect(!result.saved)
    }

    @Test func aLaterClickStopsTheEarlierFoldsRetries() async {
        let (edits, _) = edits()
        let result = await run(edits, [Failure(timedOut: true)]) {
            _ = edits.fold(group, collapsed: false)
        }
        #expect(result.sends == 1, "the stale fold must not be sent again over the newer click")
        #expect(result.refused == 0)
        #expect(edits.holdsFold(group, collapsed: false))
    }

    @Test func policy() {
        #expect(SidebarFoldPersist.after(attempt: 0, mayHaveApplied: false) == .refused)
        #expect(SidebarFoldPersist.after(attempt: 0, mayHaveApplied: true) == .retry)
        #expect(SidebarFoldPersist.after(attempt: SidebarFoldPersist.retries, mayHaveApplied: true) == .giveUp)
    }
}

/// A workspace move whose reply missed its deadline is sent again quietly on the fold's policy (Leo, 2026-11-04, on
/// "Move did not apply: set-personal-workspace: timed out: workspace.place (no reply within 2.0 seconds)").
@MainActor @Suite struct SidebarResendingTests {
    private struct Slow: Error {}
    private struct Refused: Error {}
    private let quick = Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0)

    @Test func aSlowSaveIsSentOnceMoreAndSucceeds() async throws {
        var sends = 0
        try await SidebarFoldPersist.resending(owner: "test", backoff: quick, mayHaveApplied: { $0 is Slow }) {
            sends += 1
            if sends == 1 { throw Slow() }
        }
        #expect(sends == 2, "one missed deadline is one retry")
    }

    @Test func aRefusalIsNotSentAgain() async {
        var sends = 0, thrown: (any Error)?
        do {
            try await SidebarFoldPersist.resending(owner: "test", backoff: quick, mayHaveApplied: { $0 is Slow }) {
                sends += 1
                throw Refused()
            }
        } catch { thrown = error }
        #expect(thrown is Refused)
        #expect(sends == 1)
    }

    @Test func aSaveThatNeverAnswersStopsAfterTheRetries() async {
        var sends = 0, thrown: (any Error)?
        do {
            try await SidebarFoldPersist.resending(owner: "test", backoff: quick, mayHaveApplied: { $0 is Slow }) {
                sends += 1
                throw Slow()
            }
        } catch { thrown = error }
        #expect(thrown is Slow)
        #expect(sends == SidebarFoldPersist.retries + 1)
    }
}
