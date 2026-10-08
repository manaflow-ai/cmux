import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// UPDATE-CARD (Lawrence 2026-10-06): while an update is staged, a card sits
/// above the footer with "cmux <version> is ready", an Automatic Updates
/// checkbox and one full-width Restart to Update button; hovering it shows
/// the release notes popover. Without a staged update there is no card and
/// the footer is the account and settings only. Before, a small "Update
/// Ready" pill trailed the footer line.
@MainActor @Suite(.serialized) struct SidebarUpdateCardTests {
    static let pr = URL(string: "https://github.com/manaflow-ai/cmux/pull/501")
    static let release = URL(string: "https://github.com/manaflow-ai/cmux/releases/tag/v2.0.0")
    static let card = SidebarUpdateCard(
        title: "cmux 2.0.0 is ready", buttonTitle: "Restart to Update", automaticUpdatesTitle: "Automatic Updates",
        automaticUpdates: true,
        notes: SidebarUpdateCard.Notes(
            headline: "Update 2.0.0 downloaded. Click to restart and install.",
            keepsRunning: "Your terminals and agents keep running.", whatsChangedTitle: "What's changed",
            changes: [SidebarUpdateCard.Change(title: "Newest change", author: "ada", linkTitle: "#501", url: pr),
                      SidebarUpdateCard.Change(title: "Older change")],
            moreTitle: "7 more changes", moreURL: release))

    private func sidebar(intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func show(_ card: SidebarUpdateCard?, in view: SidebarView) async {
        view.model.updateCard = card
        for _ in 0..<200 where view.updateCardView.card != card { await Task.yield() }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    @Test func noStagedUpdateShowsNoCard() {
        let view = sidebar()
        #expect(view.updateCardView.isHidden)
        #expect(view.updateCardView.frame == .zero)
    }

    /// The card sits above the footer, inset like the card stack, with its
    /// title, the checkbox and the full-width button; the list makes room.
    @Test func aStagedUpdateShowsTheCardAboveTheFooter() async {
        let view = sidebar()
        func listBottom() -> CGFloat { view.convert(view.scrollView.frame, from: view.scrollView.superview).maxY }
        let before = listBottom()
        await show(Self.card, in: view)
        let card = view.updateCardView
        #expect(!card.isHidden)
        #expect(card.frame.height == SidebarUpdateCardView.height)
        #expect(card.frame.maxY <= view.footer.frame.minY, "above the footer: \(card.frame) \(view.footer.frame)")
        #expect(abs(card.frame.minX - Metrics.space3) <= 1 && abs(card.frame.maxX - (view.bounds.width - Metrics.space3)) <= 1)
        #expect(listBottom() <= card.frame.minY + 1, "the list ends above the card")
        #expect(listBottom() < before)
        #expect(card.checkbox.title == "Automatic Updates" && card.checkbox.isOn)
        #expect(card.button.title == "Restart to Update")
        #expect(card.button.frame.width == card.bounds.width - 2 * Metrics.space3, "full width")
        await show(nil, in: view)
        #expect(card.isHidden && card.frame == .zero)
    }

    /// One click installs: the button sends `installUpdate` once; while it
    /// installs (disabled, Installing…) it sends nothing.
    @Test func theButtonSendsInstallUpdate() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        await show(Self.card, in: view)
        view.updateCardView.button.press()
        #expect(intents == [.installUpdate])
        #expect(view.updateCardView.button.accessibilityPerformPress())
        #expect(intents == [.installUpdate, .installUpdate])
        var installing = Self.card
        installing.isEnabled = false
        installing.buttonTitle = "Installing…"
        await show(installing, in: view)
        #expect(view.updateCardView.button.title == "Installing…")
        view.updateCardView.button.press()
        #expect(!view.updateCardView.button.accessibilityPerformPress())
        #expect(intents.count == 2)
    }

    /// The checkbox asks for the other state and shows the setting the
    /// model carries.
    @Test func theCheckboxSendsTheSettingAndFollowsIt() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        await show(Self.card, in: view)
        view.updateCardView.checkbox.toggle()
        #expect(intents == [.setAutomaticUpdates(false)])
        var off = Self.card
        off.automaticUpdates = false
        await show(off, in: view)
        #expect(!view.updateCardView.checkbox.isOn)
        #expect(view.updateCardView.checkbox.accessibilityValue() as? Int == 0)
        view.updateCardView.checkbox.toggle()
        #expect(intents == [.setAutomaticUpdates(false), .setAutomaticUpdates(true)])
    }

    /// The popover reads the notes: the version line, the keep-running
    /// line, What's changed with each change's title, author and PR link,
    /// then "7 more changes"; a link click sends its URL.
    @Test func thePopoverShowsTheNotesAndItsLinksOpen() async throws {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        await show(Self.card, in: view)
        let notes = view.updateCardView.notesView
        #expect(notes.shownText == [
            "Update 2.0.0 downloaded. Click to restart and install.", "Your terminals and agents keep running.",
            "What's changed", "Newest change", "ada", "#501", "Older change", "7 more changes",
        ])
        let pr = try #require(Self.pr), release = try #require(Self.release)
        #expect(notes.shownLinks.map(\.url) == [pr, release])
        notes.pressLink("#501")
        notes.pressLink("7 more changes")
        #expect(intents == [.openUpdateLink(pr), .openUpdateLink(release)])
        #expect(view.updateCardView.button.accessibilityHelp()?.contains("keep running") == true)
    }

    /// The button's default fill is a theme token (the inverted foreground),
    /// never the theme's ANSI blue.
    @Test func theButtonIsNeverBlueByDefault() async {
        let view = sidebar()
        await show(Self.card, in: view)
        let button = view.updateCardView.button
        #expect(SidebarTunables.updateCardButton.value == .inverted)
        #expect(button.fill == button.performWithTheme { Palette.textPrimary })
        #expect(button.fill != button.performWithTheme { Palette.highlight })
    }
}
