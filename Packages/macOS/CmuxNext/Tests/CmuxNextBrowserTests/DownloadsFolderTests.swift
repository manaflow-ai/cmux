import Foundation
import Testing
@testable import CmuxNextBrowser

/// A fleet kit moves the app's downloads out of the account's real ~/Downloads with
/// `CMUX_NEXT_DOWNLOADS_DIR` (Debug and bench builds). Without it every kit that
/// checks a download made macOS ask for Downloads folder access, in prompts that
/// covered the capture minis' screens (cmux18, 21, 22, 23) and broke mouse journeys.
@MainActor
@Suite struct DownloadsFolderTests {
    private let userDownloads = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)

    @Test func aDownloadWithTheVariableSetLandsInThatFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "cmux-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let chosen = DownloadsFolder(environment: [DownloadsFolder.overrideKey: folder.path(percentEncoded: false)],
                                     userDownloads: userDownloads)
        #expect(chosen.url.standardizedFileURL.pathComponents == folder.standardizedFileURL.pathComponents)

        let placement = try #require(BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "report.pdf", directory: chosen.url,
            reservations: BrowserDownloadReservations()
        ))
        defer { placement.discard() }
        #expect(placement.finalURL.deletingLastPathComponent().standardizedFileURL.pathComponents
            == folder.standardizedFileURL.pathComponents)
        #expect(placement.finalURL.lastPathComponent == "report.pdf")
    }

    @Test func withoutTheVariableDownloadsGoToTheUsersFolder() {
        #expect(DownloadsFolder(environment: [:], userDownloads: userDownloads).url == userDownloads)
    }

    @Test func anEmptyOrRelativeValueKeepsTheUsersFolder() {
        for value in ["", "downloads", "./downloads", "~/Downloads"] {
            let folder = DownloadsFolder(environment: [DownloadsFolder.overrideKey: value], userDownloads: userDownloads)
            #expect(folder.url == userDownloads, "\(value)")
        }
    }
}
