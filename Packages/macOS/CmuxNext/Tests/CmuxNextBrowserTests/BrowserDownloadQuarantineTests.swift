import Foundation
import Testing
@testable import CmuxNextBrowser

@MainActor
@Suite struct BrowserDownloadQuarantineTests {
    private enum Refusal: Error { case cannotQuarantine }

    @Test func quarantineFailureNeverPublishesOrFinishesTheDownload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let placement = try #require(BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "payload.command", directory: directory,
            reservations: BrowserDownloadReservations()
        ))
        try Data("untrusted".utf8).write(to: placement.temporaryURL)
        var quarantineURL: URL?
        let download = BrowserDownload(
            sourceURL: URL(string: "https://attacker.example/payload.command"),
            filename: placement.finalURL.lastPathComponent,
            quarantine: { file, _ in
                quarantineURL = file
                throw Refusal.cannotQuarantine
            }
        )
        download.destination = placement.finalURL
        download.placement = placement

        download.complete(.finished)

        #expect(quarantineURL == placement.temporaryURL, "quarantine must precede publication")
        guard case .failed = download.status else {
            Issue.record("quarantine failure reported \(download.status) instead of failed")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: placement.finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: placement.temporaryURL.path))
    }
}
