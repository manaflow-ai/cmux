import Foundation
import Testing
@testable import CMUXMobileCore

@Suite
struct DiagnosticReportArchiveTests {
    private func temporaryArchive() -> DiagnosticReportArchive {
        DiagnosticReportArchive(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmuxdiag-archive-\(UUID().uuidString).json")
        )
    }

    private func report(eventCount: Int) -> DiagnosticReport {
        DiagnosticReport(
            role: .mobileClient,
            anchorWallNanos: 1,
            anchorMonotonicNanos: 1,
            buildStamp: "test",
            events: (0 ..< eventCount).map {
                DiagnosticEvent(code: .connect, tNanos: UInt64($0 + 1))
            }
        )
    }

    @Test
    func savesAndReloadsAcrossInstances() {
        let archive = temporaryArchive()
        defer { archive.clear() }
        archive.save(report(eventCount: 3))

        let reloaded = DiagnosticReportArchive(fileURL: archive.fileURL).load()
        #expect(reloaded?.events.count == 3)
        #expect(reloaded?.role == .mobileClient)
    }

    @Test
    func emptyReportDoesNotReplaceStoredSnapshot() {
        let archive = temporaryArchive()
        defer { archive.clear() }
        archive.save(report(eventCount: 2))
        archive.save(report(eventCount: 0))

        #expect(archive.load()?.events.count == 2)
    }

    @Test
    func clearRemovesTheSnapshot() {
        let archive = temporaryArchive()
        archive.save(report(eventCount: 1))
        archive.clear()
        #expect(archive.load() == nil)
    }

    @Test
    func corruptFileLoadsAsNil() throws {
        let archive = temporaryArchive()
        defer { archive.clear() }
        try Data("not json".utf8).write(to: archive.fileURL)
        #expect(archive.load() == nil)
    }
}
