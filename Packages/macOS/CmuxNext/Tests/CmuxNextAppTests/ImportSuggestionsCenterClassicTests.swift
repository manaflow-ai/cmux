import CmuxNextActions
import CmuxNextBrowserImport
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import CmuxNextWakeups
import Foundation
import Testing

/// The cmux Classic card's Import as a tracked job: it runs the App's classic
/// import (the `workspace.importClassic` run, here a fake the test drives),
/// shows its progress as each classic workspace is handled, and ends with how
/// many workspaces came over. A declined preview leaves no job; a failure
/// offers Try Again; a quit leaves it paused for Resume.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ImportSuggestionsCenterClassicTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let id = "cmux.classic"
    static let classic = ImportFinding(id: id, kind: .cmuxClassic, name: "cmux Classic", count: 3)

    private struct Broke: Error {}

    /// The App's classic import, as the test drives it: each run reports progress when told
    /// and ends with the outcome the test gives.
    @MainActor final class ClassicRuns {
        private(set) var started = 0
        private var report: (@MainActor (Double) -> Void)?
        private var outcome: CheckedContinuation<Int?, any Error>?
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run(_ progress: @escaping @MainActor (Double) -> Void) async throws -> Int? {
            started += 1
            report = progress
            return try await withCheckedThrowingContinuation { continuation in
                outcome = continuation
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
        }

        /// Returns once a run is waiting for its outcome; records an issue when none starts within 10 s.
        func running() async {
            if outcome != nil { return }
            let bound = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, outcome == nil else { return }
                Issue.record("the classic import never ran")
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
            await withCheckedContinuation { waiters.append($0) }
            bound.cancel()
        }

        func progress(_ fraction: Double) { report?(fraction) }

        func end(_ result: Result<Int?, any Error>) {
            outcome?.resume(with: result)
            outcome = nil
        }
    }

    private static func center(_ runs: ClassicRuns, ledger: URL = FileManager.default.temporaryDirectory
        .appending(path: "import-jobs-\(UUID().uuidString).json")) async throws -> ImportSuggestionsCenter {
        let defaults = try #require(UserDefaults(suiteName: "import-center-\(UUID().uuidString)"))
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger, now: { Self.now })
        center.scanThisMac = { _ in [Self.classic] }
        center.host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] },
                                      openSettings: { _ in }, importClassic: { progress in try await runs.run(progress) },
                                      work: BackgroundWork(label: "test.import-cards"),
                                      mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        await withCheckedContinuation { done in center.scan { done.resume() } }
        return center
    }

    private static func card(_ center: ImportSuggestionsCenter) -> ImportCard? {
        center.list().cards.first { $0.id == id }
    }

    @Test func importRunsAsAJobWhoseProgressMovesThenSaysHowManyCameOver() async throws {
        let runs = ClassicRuns()
        let center = try await Self.center(runs)
        try center.perform(Self.id, .start)
        await runs.running()
        #expect(center.ledger.job(Self.id)?.phase == .running)
        #expect(Self.card(center)?.state == .running)
        runs.progress(1.0 / 3)
        #expect(abs((Self.card(center)?.progress ?? 0) - 1.0 / 3) < 0.001)
        runs.progress(2.0 / 3)
        #expect(abs((center.ledger.job(Self.id)?.fraction ?? 0) - 2.0 / 3) < 0.001)
        runs.end(.success(3))
        await center.settled(Self.id)
        #expect(center.ledger.job(Self.id)?.phase == .done)
        let done = try #require(Self.card(center))
        #expect(done.state == .done && done.status == "Imported 3 sessions")

        // Again from the finished card: the ledger brings nothing twice, and the card says so.
        #expect(done.primary?.action == .start)
        try center.perform(Self.id, .start)
        await runs.running()
        runs.end(.success(0))
        await center.settled(Self.id)
        #expect(runs.started == 2)
        #expect(Self.card(center)?.status == "Imported 0 sessions")
    }

    @Test func oneWorkspaceIsOneSession() async throws {
        let runs = ClassicRuns()
        let center = try await Self.center(runs)
        try center.perform(Self.id, .start)
        await runs.running()
        runs.end(.success(1))
        await center.settled(Self.id)
        #expect(Self.card(center)?.status == "Imported 1 session")
    }

    /// Settings › Import is a page: its press asks nothing of its own, since classic's preview
    /// is the native question every classic import asks before anything opens.
    @Test func aPagesPressRunsTheImportWhosePreviewAsks() async throws {
        let runs = ClassicRuns()
        let center = try await Self.center(runs)
        try center.perform(Self.id, .start, caller: ActionInvocation(arguments: [:], origin: .page))
        await runs.running()
        #expect(runs.started == 1 && center.ledger.job(Self.id)?.phase == .running)
        runs.end(.success(2))
        await center.settled(Self.id)
        #expect(Self.card(center)?.status == "Imported 2 sessions")
    }

    /// Cancel in classic's preview: nothing ran, so no job is left and the card is as before.
    @Test func aDeclinedPreviewLeavesNoJob() async throws {
        let runs = ClassicRuns()
        let center = try await Self.center(runs)
        try center.perform(Self.id, .start)
        await runs.running()
        #expect(center.ledger.job(Self.id) != nil)
        runs.end(.success(nil))
        await center.settled(Self.id)
        #expect(center.ledger.job(Self.id) == nil)
        let card = try #require(Self.card(center))
        #expect(card.state == .ready && card.primary?.action == .start)
    }

    @Test func aFailedImportOffersTryAgain() async throws {
        let runs = ClassicRuns()
        let center = try await Self.center(runs)
        try center.perform(Self.id, .start)
        await runs.running()
        runs.end(.failure(Broke()))
        await center.settled(Self.id)
        let job = try #require(center.ledger.job(Self.id))
        #expect(job.phase == .failed && job.failure == .importFailed)
        #expect(Self.card(center)?.primary?.action == .retry)
        try center.perform(Self.id, .retry)
        await runs.running()
        runs.end(.success(2))
        await center.settled(Self.id)
        #expect(runs.started == 2 && Self.card(center)?.status == "Imported 2 sessions")
    }

    /// cmux quits mid-import: the next launch finds the job paused for Resume (it does not go on
    /// by itself: its preview asks the person), and Resume runs the import again.
    @Test func aQuitMidImportLeavesItPausedForResume() async throws {
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let before = ClassicRuns()
        let quitting = try await Self.center(before, ledger: ledger)
        try quitting.perform(Self.id, .start)
        await before.running()
        before.progress(0.5)

        let runs = ClassicRuns()
        let relaunched = try await Self.center(runs, ledger: ledger)
        relaunched.restoreJobs()
        let job = try #require(relaunched.ledger.job(Self.id))
        #expect(job.phase == .paused && job.pause == .interrupted && !job.resumesQuietly)
        #expect(Self.card(relaunched)?.primary?.action == .resume)
        try relaunched.perform(Self.id, .resume)
        await runs.running()
        runs.end(.success(1))
        await relaunched.settled(Self.id)
        #expect(Self.card(relaunched)?.status == "Imported 1 session")
        // The first app's run is let go so no task is left waiting.
        before.end(.success(0))
        await quitting.settled(Self.id)
    }
}
