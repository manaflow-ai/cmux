import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CmuxNextUpdater

/// WHATS-NEW-AFTER-UPDATE W4: the page from fixture JSON. The outline is
/// the page's text snapshot (what a reader sees, in order); the hosted view
/// lays out at a window size. Pixel proof is the light/dark capture on the
/// GUI host, not this test.
@MainActor
@Suite struct WhatsNewPageSnapshotTests {
    private func fixture() throws -> WhatsNewDocument {
        try #require(WhatsNewDocument.decode(try Data(contentsOf: WhatsNewFixtures.sharedFixtureURL), origin: .bundled))
    }

    @Test func thePageFromTheFixture() throws {
        let content = WhatsNewPageContent(documents: [try fixture()], languages: ["en"])
        #expect(content.outline == """
        # cmux Nightly 1.0.0-nightly.42 (2026-10-07)
        Faster sidebar and a new What's New page
        ## New
        - See what changed after every update: After an update, a What's New item at the top of the sidebar opens a page with the highlights of every version you missed. [Try It]
        ## Fixed
        - Smoother sidebar scrolling: Long workspace lists no longer stutter while agents report status. [Learn More]
        """)
    }

    @Test func missedVersionsShowNewestFirstWithCategoriesInOrder() {
        var older = WhatsNewFixtures.document("0.65.0")
        older.entries.append(WhatsNewDocument.Entry(id: "fix", category: .fixed, title: "A fix", summary: "Fixed.",
                                                    docs: URL(string: "https://cmux.com/docs"), audience: .teams))
        older.entries.append(WhatsNewDocument.Entry(id: "safe", category: .security, title: "Safer", summary: "Patched.",
                                                    docs: URL(string: "https://cmux.com/docs")))
        let content = WhatsNewPageContent(documents: [WhatsNewFixtures.document("0.66.0"), older], languages: ["en"])
        #expect(content.sections.map(\.version) == ["0.66.0", "0.65.0"])
        #expect(content.sections[1].groups.map(\.category) == [.new, .fixed, .security])
        #expect(content.outline.contains("- A fix: Fixed. [For Teams] [Learn More]"))
    }

    /// A feed document's try-it shows only when the build allows it.
    @Test func tryItShowsOnlyWhereTheBuildMayRunIt() throws {
        var document = try fixture()
        document.origin = .feed
        let content = WhatsNewPageContent(documents: [document], languages: ["en"]) { _, origin in origin == .bundled }
        #expect(content.sections[0].groups[0].rows[0].tryIt == nil)
        #expect(!content.outline.contains("[Try It]"))
    }

    @Test func theHostedPageLaysOut() throws {
        let content = WhatsNewPageContent(documents: [try fixture()], languages: ["en"])
        let actions = WhatsNewPageActions(tryIt: { _ in }, openDocs: { _ in }, openAllNotes: {}, mediaURL: { _, _ in nil })
        let host = NSHostingView(rootView: WhatsNewPageView(content: content, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        let empty = NSHostingView(rootView: WhatsNewPageView(content: WhatsNewPageContent(documents: []), actions: actions))
        empty.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        empty.layoutSubtreeIfNeeded()
        #expect(empty.fittingSize.height > 0)
    }
}
