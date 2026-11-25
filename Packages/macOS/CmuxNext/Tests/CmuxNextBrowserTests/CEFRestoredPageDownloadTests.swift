import Foundation
@testable import CmuxNextBrowser
import Testing

/// Leo 2026-11-22 ("constant rerenders on every fucking page still"): a restored tab whose address is a file (a
/// raw.githubusercontent .mp4) downloaded that file again at every relaunch. A restored page's own load, with no
/// gesture, starts no download; a download the user starts, or cmux itself, still does.
@MainActor @Suite(.serialized) struct CEFRestoredPageDownloadTests {
    final class Shim {
        var answers: [(id: Int32, path: String)] = []
        var starts: [(browser: Int32, url: String)] = []
        lazy var value = CEFDownloadShim(start: { [unowned self] browser, url in starts.append((browser, url)); return true },
                                         answer: { [unowned self] id, path in answers.append((id, path)) },
                                         control: { _, _ in })
    }

    private static let video = "https://raw.githubusercontent.com/example/repo/main/clip.mp4"

    private func downloads(_ shim: Shim, refusing: Set<Int32>) -> (CEFDownloads, () -> Int) {
        let downloads = CEFDownloads(shim: { shim.value })
        downloads.directory = { FileManager.default.temporaryDirectory.appending(path: "cef-restored-downloads-\(UUID().uuidString)") }
        downloads.refusesWithoutGesture = { refusing.contains($0) }
        var asked = 0
        downloads.admit = { _, _ in asked += 1 }  // never answers: a test of who asks, not of the gate
        return (downloads, { asked })
    }

    @Test func aRestoredPagesOwnLoadStartsNoDownload() {
        let shim = Shim()
        let (downloads, asked) = downloads(shim, refusing: [7])
        downloads.handle(.started(id: 1, browser: 7, url: Self.video, suggestedName: "clip.mp4", totalBytes: 40_000_000))
        #expect(shim.answers.count == 1)
        #expect(shim.answers.first?.id == 1)
        #expect(shim.answers.first?.path == "", "an empty path cancels the download")
        #expect(asked() == 0, "it never reaches the automatic-downloads gate")
    }

    @Test func anotherTabsDownloadStillAsksTheGate() {
        let shim = Shim()
        let (downloads, asked) = downloads(shim, refusing: [7])
        downloads.handle(.started(id: 2, browser: 8, url: Self.video, suggestedName: "clip.mp4", totalBytes: nil))
        #expect(shim.answers.isEmpty)
        #expect(asked() == 1)
    }

    @Test func aDownloadCmuxStartsGoesAheadOnARestoredPage() {
        let shim = Shim()
        let (downloads, asked) = downloads(shim, refusing: [7])
        #expect(downloads.download(Self.video, browser: 7))
        downloads.handle(.started(id: 3, browser: 7, url: Self.video, suggestedName: "clip.mp4", totalBytes: nil))
        #expect(asked() == 0)
        #expect(shim.answers.count == 1)
        #expect(shim.answers.first?.path.isEmpty == false, "the download got a path: it runs")
    }
}
