import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Page download ledger") @MainActor
struct BrowserPageDownloadLedgerTests {
    private let temp = URL(fileURLWithPath: "/tmp/cmux-downloads", isDirectory: true)

    private func makeLedger() -> BrowserPageDownloadLedger {
        var next = 0
        return BrowserPageDownloadLedger(temporaryDirectory: temp, makeID: {
            next += 1
            return "dl-\(next)"
        })
    }

    private func download(_ id: String = "7", name: String? = "report.pdf", state: BrowserPageDownload.State = .pending,
                          received: Int64 = 0, expected: Int64? = nil) -> BrowserPageDownload {
        BrowserPageDownload(id: id, url: URL(string: "https://example.com/files/report.pdf"), suggestedFilename: name,
                            receivedBytes: received, expectedBytes: expected, state: state)
    }

    @Test func stageWritesToAUniqueTemporaryFileLikeWebKit() {
        let ledger = makeLedger()
        let staged = ledger.stage(download())
        #expect(staged.downloadID == "dl-1")
        #expect(staged.temporaryURL == temp.appendingPathComponent("dl-1-report.pdf"))
        #expect(staged.suggestedFilename == "report.pdf")
        #expect(staged.sourceURL == URL(string: "https://example.com/files/report.pdf"))
        #expect(ledger.activeCount == 1)
    }

    @Test func askingAgainForTheSameDownloadKeepsItsFile() {
        let ledger = makeLedger()
        let first = ledger.stage(download())
        #expect(ledger.stage(download()) == first)
        #expect(ledger.activeCount == 1)
    }

    @Test func unsafeOrMissingNamesAreSanitized() {
        let ledger = makeLedger()
        let traversal = ledger.stage(download("1", name: "../../etc/passwd"))
        #expect(!traversal.suggestedFilename.contains("/"))
        #expect(traversal.temporaryURL.deletingLastPathComponent() == temp)
        let unnamed = ledger.stage(download("2", name: nil))
        #expect(unnamed.suggestedFilename == "report.pdf")
    }

    @Test func progressThenCompletionEndsOnce() {
        let ledger = makeLedger()
        let staged = ledger.stage(download())
        #expect(ledger.apply(download(state: .pending)) == nil)
        #expect(ledger.apply(download(state: .inProgress, received: 10, expected: 100))
            == .progress(staged, receivedBytes: 10, expectedBytes: 100))
        #expect(ledger.apply(download(state: .completed, received: 100, expected: 100)) == .finished(staged))
        #expect(ledger.apply(download(state: .completed)) == nil)
        #expect(ledger.activeCount == 0)
    }

    @Test func cancelAndFailureEndTheDownload() {
        let ledger = makeLedger()
        let a = ledger.stage(download("a"))
        let b = ledger.stage(download("b"))
        #expect(ledger.apply(download("a", state: .cancelled)) == .cancelled(a))
        #expect(ledger.apply(download("b", state: .failed("interrupted (20)"))) == .failed(b, message: "interrupted (20)"))
        #expect(ledger.activeCount == 0)
    }

    @Test func reportsForUnstagedDownloadsAreIgnored() {
        let ledger = makeLedger()
        #expect(ledger.apply(download("ghost", state: .completed)) == nil)
    }

    @Test func drainReturnsEveryActiveDownload() {
        let ledger = makeLedger()
        _ = ledger.stage(download("a"))
        _ = ledger.stage(download("b"))
        #expect(Set(ledger.drain().map(\.engineDownloadID)) == ["a", "b"])
        #expect(ledger.activeCount == 0)
    }
}
