import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The user's own hover card (`cmux.hovercard/1` in `~/.config/cmux/customize/`) draws on the card as it opens,
/// and a card that fails says why there. Since the card grew Show details (#28897) both stayed hidden until the
/// person clicked it, so a working card never drew and a broken one showed no error: only the built-in card.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardCustomCardTests {
    /// A mounted custom card with a fixed state: ready with one line of text, loading, or failed with `error`.
    private final class FakeCard: SidebarCustomContent {
        let view: NSView
        let isReady: Bool
        let errorText: String?
        var onChange: (() -> Void)?

        init(text: String?, ready: Bool, error: String? = nil) {
            let stack = NSStackView(views: text.map { [NSTextField(labelWithString: $0)] } ?? [])
            stack.orientation = .vertical
            view = stack
            isReady = ready
            errorText = error
        }

        func preferredHeight(width: CGFloat) -> CGFloat { 18 }
        func release() {}
    }

    private func card() -> WorkspaceHoverCardView {
        let card = WorkspaceHoverCardView()
        card.configure(.make(SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-custom"), title: "Deploy"), machine: nil, now: Date()))
        card.configureTabs(title: "ws-custom", tabs: [SidebarTab(id: TabID("t1"), title: "zsh")])
        return card
    }

    @Test func theUserCardDrawsWithoutShowDetails() {
        let card = card()
        #expect(!card.isDetailsExpanded)
        card.setCustom(FakeCard(text: "studio card", ready: true))
        #expect(card.lines.first == "custom card", "the user's card stays hidden until Show details: \(card.lines)")
        #expect(card.lines.contains("studio card"), "\(card.lines)")
    }

    @Test func theUserCardStaysAcrossShowAndHideDetails() {
        let card = card()
        card.setCustom(FakeCard(text: "studio card", ready: true))
        card.expandDetails()
        #expect(card.lines.first == "custom card", "\(card.lines)")
        card.resetDetails()
        #expect(card.lines.first == "custom card", "Hide details hid the user's card: \(card.lines)")
    }

    @Test func aFailedUserCardSaysWhyWithoutShowDetails() {
        let card = card()
        card.setCustom(FakeCard(text: nil, ready: false, error: "Line 2, column 12: expecting ';'"))
        let error = Strings.customCardError("Line 2, column 12: expecting ';'")
        #expect(card.lines.contains(error), "the error hides until Show details: \(card.lines)")
        #expect(card.lines.first != "custom card")
    }

    @Test func aLoadingUserCardKeepsTheBuiltInCardWithNoError() {
        let card = card()
        card.setCustom(FakeCard(text: "studio card", ready: false))
        #expect(card.lines.first != "custom card")
        #expect(!card.lines.contains { $0.hasPrefix(Strings.customCardError("")) }, "\(card.lines)")
    }
}
