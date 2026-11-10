import AppKit
@testable import CmuxNextFeed
import CmuxNextTestSupport
import Foundation
import Testing

/// ui-state-fixes M4: the Feed said "Nothing new" and the reports basket "No agent reports yet"
/// by emptiness alone, before the owner or the mailbox had answered. Both show a loading state
/// until their data was read, then the empty state when it is truly empty.
@MainActor @Suite(.closesItsWindows) struct FeedLoadingStateTests {
    private func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    private func visibleTexts(in view: NSView) -> Set<String> {
        Set(subviews(of: view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue))
    }

    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test func theListIsLoadingUntilTheFirstSnapshotThenEmpty() {
        let model = FeedModel(source: MockFeedSource(snapshot: FeedSnapshot(revision: 1, user: "u", device: "d", items: [])))
        #expect(!model.summary.loaded)
        let pane = FeedListPane(model: model)
        let shown = window(pane)
        defer { shown.close() }
        #expect(visibleTexts(in: pane).contains(FeedStrings.loading))
        #expect(!visibleTexts(in: pane).contains(FeedStrings.empty), "the Feed said Nothing new before the owner answered")
        model.start()
        #expect(model.summary.loaded, "an empty first snapshot left the chrome loading")
        #expect(model.summary.listIsEmpty)
    }

    @Test func theBasketIsLoadingUntilTheMailboxIsRead() async {
        let model = FeedModel(source: MockFeedSource())
        let view = ReportsBasketView(model: model, onReply: nil)
        let shown = window(view)
        defer { shown.close() }
        #expect(visibleTexts(in: view).contains(FeedStrings.reportsLoading))
        #expect(!visibleTexts(in: view).contains(FeedStrings.reportsEmpty), "the basket said No agent reports yet before the mailbox was read")
        _ = model.replaceReports([String: FeedReport]())
        #expect(model.reportsLoaded)
        let deadline = ContinuousClock.now + .seconds(5)
        while !visibleTexts(in: view).contains(FeedStrings.reportsEmpty), ContinuousClock.now < deadline { await Task.yield() }
        #expect(visibleTexts(in: view).contains(FeedStrings.reportsEmpty))
        #expect(!visibleTexts(in: view).contains(FeedStrings.reportsLoading))
    }
}
