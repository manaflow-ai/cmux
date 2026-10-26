@testable import CmuxNextBrowser
import Foundation
import Testing

/// `cmux browser … download wait` (`BrowserDownloadWaits`): a wait follows the click's download even when it
/// started before the wait, a wait that times out gives its download back to the next wait, and one download
/// goes to one wait.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserDownloadWaitsTests {
    private func download(_ name: String) -> BrowserDownload {
        BrowserDownload(sourceURL: URL(string: "https://example.com/\(name)"), filename: name, quarantine: { _, _ in })
    }

    @Test func aDownloadThatStartedBeforeTheWaitIsTheOneItFollows() async {
        let waits = BrowserDownloadWaits()
        let item = download("report.pdf")
        waits.started(item, tab: "tab_a")
        item.complete(.finished)

        let answer = await waits.ended(id: nil, tab: "tab_a", items: [item], within: .seconds(5))

        guard case .ended(let ended) = answer else { Issue.record("answered \(answer)"); return }
        #expect(ended === item)
    }

    @Test func aWaitThatTimesOutGivesItsDownloadBackToTheNextWait() async {
        let waits = BrowserDownloadWaits()
        let item = download("big.iso")
        waits.started(item, tab: "tab_a")

        let first = await waits.ended(id: nil, tab: "tab_a", items: [item], within: .milliseconds(50))
        guard case .timedOut = first else { Issue.record("first wait answered \(first)"); return }
        Task { @MainActor in item.complete(.finished) }
        let second = await waits.ended(id: nil, tab: "tab_a", items: [item], within: .seconds(5))

        guard case .ended(let ended) = second else { Issue.record("the retry did not follow the download: \(second)"); return }
        #expect(ended === item)
    }

    @Test func oneNewDownloadGoesToOneWait() async {
        let waits = BrowserDownloadWaits()
        let item = download("a.zip")
        async let first = waits.ended(id: nil, tab: "tab_a", items: [], within: .milliseconds(400))
        async let second = waits.ended(id: nil, tab: "tab_a", items: [], within: .milliseconds(400))
        Task { @MainActor in
            waits.started(item, tab: "tab_a")
            item.complete(.finished)
        }

        let answers = await [first, second]
        let ended = answers.filter { if case .ended = $0 { true } else { false } }.count
        #expect(ended == 1, "\(ended) waits got the one download")
    }
}
