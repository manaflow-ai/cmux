import CmuxNextBrowserImport
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// The sidebar's Import from Conductor note as the center keeps it: it goes at Conductor Cloud's
/// shutdown while cmux stays open (one wake, no polling), and a finished import keeps it gone
/// after the job ledger prunes the finished job.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ImportSuggestionsCenterConductorTests {
    static let id = "agents.conductor"
    static let conductor = ImportFinding(id: id, kind: .conductor, name: "Conductor", count: 2)
    /// A week before the deadline.
    static let weekBefore = Date(timeIntervalSince1970: 1_794_556_800)

    private static func center(now: @escaping () -> Date, opened: Int? = 2) async throws -> ImportSuggestionsCenter {
        let defaults = try #require(UserDefaults(testSuiteName: "import-center-conductor-\(UUID().uuidString)"))
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger, now: now)
        center.scanThisMac = { _ in [Self.conductor] }
        center.host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] },
                                      openSettings: { _ in }, importClassic: { _ in nil }, importConductor: { _ in opened })
        await withCheckedContinuation { done in center.scan { done.resume() } }
        return center
    }

    /// cmux open across the deadline: the note on screen is read again then, and goes, though
    /// nothing else it reads changed (the clock the center reads still says before the deadline).
    @Test func theNoteGoesAtTheDeadlineWhileCmuxStaysOpen() async throws {
        let justBefore = ImportSuggestionState.conductorDeadline.addingTimeInterval(-0.05)
        let center = try await Self.center(now: { justBefore })
        #expect(center.conductorNote != nil)
        let changed = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = center.conductorNote } onChange: { changed.continuation.yield() }
        center.scheduleConductorDeadline()
        var iterator = changed.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(center.conductorDeadlinePassed)
        #expect(center.conductorNote == nil)
    }

    /// Started after the deadline: no wait, the note is gone at once.
    @Test func pastTheDeadlineTheNoteIsGoneAtOnce() async throws {
        let center = try await Self.center(now: { ImportSuggestionState.conductorDeadline.addingTimeInterval(1) })
        center.scheduleConductorDeadline()
        #expect(!center.conductorDeadline.isScheduled)
        #expect(center.conductorDeadlinePassed && center.conductorNote == nil)
    }

    /// A finished import is kept in the state, so pruning its job (14 days on) does not bring the
    /// note back; a declined preview keeps nothing, so the note is still offered.
    @Test func aFinishedImportKeepsTheNoteGoneAfterItsJobIsPruned() async throws {
        let center = try await Self.center(now: { Self.weekBefore })
        #expect(center.conductorNote != nil)
        try center.perform(Self.id, .start)
        await center.settled(Self.id)
        #expect(center.ledger.job(Self.id)?.phase == .done)
        #expect(center.state.conductorImportRan == true)
        center.ledger.remove(Self.id)
        #expect(center.conductorNote == nil)

        let declined = try await Self.center(now: { Self.weekBefore }, opened: nil)
        try declined.perform(Self.id, .start)
        await declined.settled(Self.id)
        #expect(declined.state.conductorImportRan == nil)
        #expect(declined.conductorNote != nil)
    }

    /// The capture seam (`debug.import_note`): on a Mac whose scan found no Conductor, and with the
    /// note closed before, the stand-in finding brings the sidebar note and the Settings › Import
    /// card back, and the note reads the generic copy.
    @Test func theCaptureFixtureShowsTheNoteWithNoConductorHere() async throws {
        let center = try await Self.center(now: { Self.weekBefore })
        center.scanThisMac = { _ in [] }
        await withCheckedContinuation { done in center.scan { done.resume() } }
        #expect(center.conductorNote == nil)
        center.showConductorNoteFixture()
        let note = try #require(center.conductorNote)
        #expect(note.title == ConductorImportStrings.noteTitle)
        #expect(center.list().cards.contains { $0.id == Self.id })
        _ = center.answerConductorNote(ImportSuggestionsCenter.conductorNoteID, action: nil)
        #expect(center.conductorNote == nil)
        center.showConductorNoteFixture()
        #expect(center.conductorNote != nil)
    }
}
