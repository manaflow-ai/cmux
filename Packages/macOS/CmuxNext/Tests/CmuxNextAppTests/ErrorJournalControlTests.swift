import CmuxNextControl
import CmuxNextErrorJournal
import Foundation
import Testing

@testable import CmuxNextApp

@Suite struct ErrorJournalControlTests {
    @Test func failedClearIsAProtocolFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("error-journal-control-\(UUID().uuidString)")
        let journal = ErrorJournal(directory: directory)
        await journal.record(ErrorEvent(source: "app", level: .error, message: "clear failure"))
        await journal.flush()
        let segment = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "ndjson" }
        )
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: segment.path) }

        let control = ErrorJournalControl(journal: journal, sources: [])
        do {
            _ = try await control.clear([:])
            Issue.record("errors.clear reported success after persistence failed")
        } catch let error as ControlError {
            #expect(error.code == "operation_failed")
            #expect(error.data?.objectValue?["removed"] == .number(0))
        }
    }
}
