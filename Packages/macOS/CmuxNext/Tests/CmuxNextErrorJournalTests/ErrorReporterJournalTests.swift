@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// cmux's own error is in the journal when it happens, so a run that ends without a quit (a crash,
/// a force quit, SIGKILL, power loss) keeps it. Before, an app error reached the journal only
/// through the log harvest (``OSLogErrorSource``), at launch, at quit and on `errors.list`; the
/// next launch cannot read an ended process's log store, so a crash lost every app error of the
/// session.
@Suite struct ErrorReporterJournalTests {
    private let directory = FileManager().temporaryDirectory.appendingPathComponent("error-reporter-\(UUID().uuidString)")

    /// Record an app error, end the "process" with no stop, no flush and no harvest, relaunch:
    /// the next launch's journal has it. (`flushBatch: 1` makes the journal write when it folds the
    /// event instead of after its 2 s batch deadline; the batch timing is the journal's own,
    /// ErrorJournalTests. Here only the path is under test.)
    @Test func anAppErrorIsInTheNextLaunchsJournalWithNoStopAndNoHarvest() async throws {
        let journal = ErrorJournal(directory: directory, limits: ErrorJournalLimits(flushBatch: 1))
        let errors = ErrorReporter(category: "daemon.reconnect", recorder: journal)
        await errors.error("reconnect failed: \("connection refused", privacy: .public) token=abc123secret").value

        // The next launch: another journal on the folder reads what is on disk.
        let entry = try #require(await ErrorJournal(directory: directory).entries().first,
                                 "the app error is not in the journal without a harvest")
        #expect(entry.source == "app")
        #expect(entry.level == .error)
        #expect(entry.sample.hasPrefix("reconnect failed: connection refused token=<redacted>"))
        #expect(entry.context["category"] == "daemon.reconnect")
    }

    /// The fault reported just before a crash is the one that explains it. With the journal's own
    /// limits a record only folded into memory and armed the 2 s batch write, so a crash a second
    /// later lost it. A fault is now on disk when its record ends: the next launch's journal has it
    /// with no flush, no stop and no harvest.
    @Test func aFaultIsOnDiskWhenItsRecordEnds() async throws {
        let journal = ErrorJournal(directory: directory)
        let errors = ErrorReporter(category: "layout", recorder: journal)
        await errors.fault("pane tree lost its root").value

        let entry = try #require(await ErrorJournal(directory: directory).entries().first,
                                 "the fault waits for the journal's batch write")
        #expect(entry.level == .fault)
        #expect(entry.sample == "pane tree lost its root")
        withExtendedLifetime(journal) {}
    }

    /// As with `Logger`: a value without `privacy:` shows as `<private>`, in the log and the journal.
    @Test func aValueWithoutPrivacyIsPrivateAndNumbersArePublic() async throws {
        let journal = ErrorJournal(directory: directory, limits: ErrorJournalLimits(flushBatch: 1))
        let path = "/Users/someone/secret-project"
        let tries = 3
        await ErrorReporter(category: "files", recorder: journal).fault("open \(path) failed after \(tries) tries").value
        let entry = try #require(await journal.entries().first)
        #expect(entry.level == .fault)
        #expect(entry.sample == "open <private> failed after 3 tries")
    }
}
