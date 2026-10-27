import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The find bar over an engine that reports every result (p01-process-048 of
/// plans/cmux-next/chrome-parity/p01-process.md). In host mode a whole wire batch of FIND_RESULT
/// events runs in one main-thread turn: the first final result answers the search and every
/// result updates the pill. The pill and the model end on the last result Chromium sent, as
/// Chrome's find bar does (`FindBarController::OnFindResultAvailable`).
@MainActor @Suite struct FindBarViewTests {
    @Test func theLastUpdateOfTheSearchStaysAfterTheAnswer() async {
        let tab = ScriptedFindTab()
        let model = BrowserFindModel()
        let bar = FindBarView(model: model)
        bar.tab = tab

        bar.pill.simulateTyping("ab")
        let search = await tab.nextSearch()
        #expect(search.text == "ab")

        // One batch: a Find Next answered by the previous step's final result, then its own.
        let first = BrowserFindResult(matchFound: true, matchCount: 3, currentIndex: 2)
        let last = BrowserFindResult(matchFound: true, matchCount: 3, currentIndex: 3)
        search.answer(first)
        search.update(first)
        search.update(last)
        await bar.findTask?.value

        #expect(bar.pill.countText == Strings.findPosition(3, of: 3), "the answer must not overwrite the later update")
        #expect(model.matchCount == 3 && model.activeIndex == 2)
    }

    /// A search that ends with no result (the page went away) still shows its answer.
    @Test func anAnswerWithNoUpdateShows() async {
        let tab = ScriptedFindTab()
        let model = BrowserFindModel()
        let bar = FindBarView(model: model)
        bar.tab = tab

        bar.pill.simulateTyping("zz")
        let search = await tab.nextSearch()
        search.answer(.none)
        await bar.findTask?.value

        #expect(bar.pill.countText == Strings.findNoMatches)
        #expect(model.matchCount == 0 && model.activeIndex == nil)
    }
}

/// A tab whose find the test answers and updates by hand.
@MainActor private final class ScriptedFindTab: BrowserTab, BrowserFindUpdating {
    /// One search the bar started: its query, its answer and its update closure.
    struct Search {
        let text: String
        let answer: (BrowserFindResult) -> Void
        let update: (BrowserFindResult) -> Void
    }

    let id = BrowserTabID.random()
    let engineKind: BrowserEngineKind = .cef
    let profileID = BrowserProfileID(rawValue: UUID())
    let presentation: BrowserPresentation = .inView
    let contentView = NSView()
    let state = BrowserTabState()
    let favicon: NSImage? = nil
    let pendingPrompts: [BrowserPrompt] = []
    weak var delegate: (any BrowserTabDelegate)?
    weak var keyRouter: (any BrowserKeyRouting)?

    private var started: [Search] = []
    private var waiter: CheckedContinuation<Void, Never>?

    /// The next search the bar starts.
    func nextSearch() async -> Search {
        if started.isEmpty { await withCheckedContinuation { waiter = $0 } }
        return started.removeFirst()
    }

    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool,
              update: @escaping (BrowserFindResult) -> Void) async -> BrowserFindResult {
        await withCheckedContinuation { continuation in
            started.append(Search(text: text, answer: { continuation.resume(returning: $0) }, update: update))
            waiter?.resume()
            waiter = nil
        }
    }

    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        await find(text, direction: direction, caseSensitive: caseSensitive) { _ in }
    }

    func clearFind() {}
    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stop() {}
    func setFocused(_ focused: Bool) {}
    func setContentVisible(_ visible: Bool) {}
    func snapshot() async throws -> CGImage { throw BrowserTabError.snapshotUnavailable }
    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        throw BrowserTabError.unsupported("evaluate")
    }
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}
