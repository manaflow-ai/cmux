import CmuxNextBrowserImport
@testable import CmuxNextImportSuggestions
import Foundation
import Testing

/// Import from Conductor pointed out outside Settings › Import: the sidebar's one-time note and
/// the first-run history page's line, each only while this Mac has Conductor and before Conductor
/// Cloud shuts down on November 20.
struct ConductorNoteTests {
    /// A week before the deadline.
    static let now = Date(timeIntervalSince1970: 1_794_556_800)
    static let conductor = ImportFinding(id: "agents.conductor", kind: .conductor, name: "Conductor", count: 3)

    @Test func theNoteShowsWhileConductorIsHereAndNotImported() {
        #expect(ImportSuggestionState().showsConductorNote(findings: [ImportCardDeckTests.claude, Self.conductor], jobs: ImportJobLedger(), now: Self.now))
    }

    @Test func theNoteNeedsConductor() {
        #expect(!ImportSuggestionState().showsConductorNote(findings: [ImportCardDeckTests.claude], jobs: ImportJobLedger(), now: Self.now))
        #expect(!ImportSuggestionState().showsConductorNote(findings: [], jobs: ImportJobLedger(), now: Self.now))
    }

    @Test func theNoteEndsAtTheDeadline() {
        let state = ImportSuggestionState()
        let deadline = ImportSuggestionState.conductorDeadline
        #expect(state.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: deadline.addingTimeInterval(-1)))
        #expect(!state.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: deadline))
        #expect(!state.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: deadline.addingTimeInterval(86_400)))
    }

    /// Its x closes it for good, and the closed note survives a save and a load.
    @Test func aClosedNoteNeverShowsAgain() throws {
        var state = ImportSuggestionState()
        state.conductorNoteClosed = true
        #expect(!state.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: Self.now))
        let suite = "conductor-note-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        state.save(to: defaults)
        #expect(ImportSuggestionState.load(from: defaults).conductorNoteClosed == true)
    }

    /// The state saved before the note existed still loads, with its dismissals.
    @Test func stateSavedBeforeTheNoteStillLoads() throws {
        let suite = "conductor-note-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"dismissed":{"agents.codex":"agents.codex|ok"},"requests":[]}"#.utf8), forKey: ImportSuggestionState.defaultsKey)
        let state = ImportSuggestionState.load(from: defaults)
        #expect(state.dismissed == ["agents.codex": "agents.codex|ok"])
        #expect(state.conductorNoteClosed == nil)
        #expect(state.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: Self.now))
    }

    /// Once the import started (running, or done) the note goes; so does a Conductor card the
    /// person hid in Settings › Import (Done after the import removes the job and hides the card).
    @Test func theNoteGoesOnceTheImportRan() {
        var running = ImportJobLedger()
        running.put(ImportJob(finding: Self.conductor, now: Self.now))
        #expect(!ImportSuggestionState().showsConductorNote(findings: [Self.conductor], jobs: running, now: Self.now))

        var job = ImportJob(finding: Self.conductor, now: Self.now)
        job.importedClassic(3, now: Self.now)
        var done = ImportJobLedger()
        done.put(job)
        #expect(!ImportSuggestionState().showsConductorNote(findings: [Self.conductor], jobs: done, now: Self.now))

        var hidden = ImportSuggestionState()
        hidden.dismiss(Self.conductor)
        #expect(!hidden.showsConductorNote(findings: [Self.conductor], jobs: ImportJobLedger(), now: Self.now))
    }

    @Test func theOnboardingLineNeedsConductorAndTheDeadline() throws {
        let home = try ImportScannerTests.Home(["conductor/workspaces/app/lima/README"])
        #expect(ImportScanner(home: home.url).conductorOnboardingLine(now: Self.now) == ConductorImportStrings.onboardingLine)
        #expect(ImportScanner(home: home.url).conductorOnboardingLine(now: ImportSuggestionState.conductorDeadline) == nil)
        let database = try ImportScannerTests.Home(["Library/Application Support/com.conductor.app/conductor.db"])
        #expect(ImportScanner(home: database.url).conductorOnboardingLine(now: Self.now) != nil)
        let empty = try ImportScannerTests.Home()
        #expect(ImportScanner(home: empty.url).conductorOnboardingLine(now: Self.now) == nil)
    }
}
