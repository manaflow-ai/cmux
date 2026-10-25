#if DEBUG
@testable import CmuxNextBrowser
@testable import CmuxNextCompat
import Foundation
import Testing

/// A finished download moves into place off the main thread (`BrowserDownloadPlacement.finish`):
/// the replace or the exclusive rename can block on a slow or network volume. The download stays in
/// progress until it lands, then finishes or fails where it always did (its status and the finish
/// handlers), and an end that comes while it lands is ignored.
@MainActor @Suite struct BrowserDownloadLandingTests {
    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-landing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Completes `download` under a recording blocking table, cancels it at once (too late: it is
    /// landing), and returns the status its finish handler saw and the main-thread sites in the
    /// placement's file.
    private static func land(_ download: BrowserDownload) async -> (BrowserDownload.Status, [String]) {
        let table = BlockingViolationTable(mode: .record)
        let ended = await BlockingViolationTable.$scoped.withValue(table) {
            await withCheckedContinuation { (continuation: CheckedContinuation<BrowserDownload.Status, Never>) in
                download.onFinish { continuation.resume(returning: $0.status) }
                download.complete(.finished)
                download.cancel()
            }
        }
        await table.flush()
        let onMain = BlockingDetector(table: table).sites.map(\.location).filter { $0.contains("BrowserDownloadPlacement.swift") }
        return (ended, onMain)
    }

    @Test func aFinishedDownloadLandsOffTheMainThreadThenFinishes() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let placement = try #require(BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "report.pdf", directory: directory, reservations: BrowserDownloadReservations()))
        try Data("report".utf8).write(to: placement.temporaryURL)
        let download = BrowserDownload(sourceURL: URL(string: "https://example.com/report.pdf"),
                                       filename: placement.finalURL.lastPathComponent, quarantine: { _, _ in })
        download.destination = placement.finalURL
        download.placement = placement

        let (ended, onMain) = await Self.land(download)

        #expect(ended == .finished, "the late cancel while it landed is ignored")
        #expect(download.status == .finished)
        #expect(download.fraction == 1)
        #expect(download.destination == placement.finalURL)
        #expect(FileManager.default.contents(atPath: placement.finalURL.path) == Data("report".utf8))
        #expect(!FileManager.default.fileExists(atPath: placement.temporaryURL.path))
        #expect(onMain.isEmpty, "the landing's file I/O ran on the main thread at \(onMain)")
    }

    /// A file the person chose in a save panel is replaced only by the complete download.
    @Test func aChosenFileIsReplacedOffTheMainThread() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chosen = directory.appendingPathComponent("kept.txt")
        try Data("old".utf8).write(to: chosen)
        let placement = try #require(BrowserDownloadPolicy.place(
            chosen: chosen, suggestedFilename: "kept.txt", directory: directory, reservations: BrowserDownloadReservations()))
        try Data("new".utf8).write(to: placement.temporaryURL)
        let download = BrowserDownload(sourceURL: URL(string: "https://example.com/kept.txt"),
                                       filename: chosen.lastPathComponent, quarantine: { _, _ in })
        download.placement = placement

        let (ended, onMain) = await Self.land(download)

        #expect(ended == .finished)
        #expect(download.destination == chosen)
        #expect(FileManager.default.contents(atPath: chosen.path) == Data("new".utf8))
        #expect(onMain.isEmpty, "the landing's file I/O ran on the main thread at \(onMain)")
    }
}
#endif
