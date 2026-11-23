import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Testing

/// https://github.com/manaflow-ai/cmux/issues/50981: the Update Available card showed a "Hide" text button in its
/// top right corner where every other card shows an x ("why is there no x instead of the Hide? that's weird").
/// The found-update notice, its sibling results (cmux Is Up to Date) and the staged Update Ready card all show the
/// cards' one corner x, labelled Hide for an update, centred on the title's row; one click on the update's x hides
/// it at once (its remind-later items stay on the right-click menu).
@MainActor @Suite(.serialized) struct UpdateCardCloseXTests {
    static let width: CGFloat = 240

    private func noticeView(_ card: UpdateCard) -> SidebarNoticeCardView {
        _ = NSApplication.shared
        let notice = SidebarCardFeed.notice(card.presentation(version: "1.0.0", build: "100"), asked: true)
        let view = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: Self.width,
                                                       height: SidebarNoticeCardView.height(for: notice, width: Self.width)))
        view.configure(notice)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Text buttons the card shows (a "Hide" text button among them was the bug).
    private func shownTextButtons(in view: NSView) -> [SidebarCardTextButton] {
        view.subviews.flatMap { sub -> [SidebarCardTextButton] in
            let own = (sub as? SidebarCardTextButton).map { $0.isHidden ? [] : [$0] } ?? []
            return own + shownTextButtons(in: sub)
        }
    }

    private func expectCenteredOnTitle(_ close: NSRect, _ title: NSRect, font: NSFont, _ name: String) {
        let titleMid = title.minY + ceil(font.boundingRectForFont.height) / 2
        #expect(abs(close.midY - titleMid) <= 1, "\(name): the x's centre \(close.midY) is off the title's \(titleMid)")
        #expect(close.minX >= title.maxX, "\(name): the title \(title) runs under the x \(close)")
    }

    @Test func theFoundUpdateShowsTheXLabelledHide() {
        let view = noticeView(.available(version: "nightly 200"))
        #expect(!view.closeButton.isHidden, "the Update Available card shows no x")
        #expect(shownTextButtons(in: view).isEmpty, "the Update Available card still shows a text button: \(shownTextButtons(in: view).map(\.title))")
        #expect(view.closeButton.label == "Hide")
        #expect(view.closeButton.accessibilityLabel() == "Hide")
        #expect(view.closeButton.themedToolTip == "Hide")
        let close = view.convert(view.closeButton.frame, from: view.closeButton.superview)
        let title = view.convert(view.titleLabel.frame, from: view.titleLabel.superview)
        expectCenteredOnTitle(close, title, font: view.titleLabel.font ?? .systemFont(ofSize: 13), "Update Available")
    }

    /// The found update's x hides it on one click (as the text button did), with no menu in the way.
    @Test func theFoundUpdatesXHidesAtOnce() {
        let view = noticeView(.available(version: "nightly 200"))
        var dismissed: [String] = []
        view.onDismiss = { dismissed.append($0) }
        #expect(view.dismissMenu == nil, "the x opens a menu instead of hiding")
        #expect(view.closeButton.accessibilityPerformPress())
        #expect(dismissed == [SidebarCardFeed.updateCardID])
        // Remind Me Later stays on the right-click menu.
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let menu = click.flatMap { view.menu(for: $0) }
        let titles = menu?.items.map(\.title) ?? []
        for option in UpdateCardCloseOption.allCases { #expect(titles.contains(option.title), "the right-click menu lost \(option.title)") }
    }

    /// cmux Is Up to Date (the found update's sibling) shows the same x, the same size, on the title's row.
    @Test func theUpToDateResultShowsTheSameX() {
        let found = noticeView(.available(version: "nightly 200")), upToDate = noticeView(.note(.upToDate))
        #expect(!upToDate.closeButton.isHidden)
        #expect(shownTextButtons(in: upToDate).isEmpty)
        #expect(upToDate.closeButton.frame.size == found.closeButton.frame.size)
        #expect(upToDate.closeButton.frame.origin == found.closeButton.frame.origin)
        let close = upToDate.convert(upToDate.closeButton.frame, from: upToDate.closeButton.superview)
        let title = upToDate.convert(upToDate.titleLabel.frame, from: upToDate.titleLabel.superview)
        expectCenteredOnTitle(close, title, font: upToDate.titleLabel.font ?? .systemFont(ofSize: 13), "cmux Is Up to Date")
    }

    /// The staged Update Ready card shows the corner x labelled Hide too, in every layout with a title.
    @Test(arguments: [SidebarUpdateCardLayout.card, .compact])
    func theUpdateReadyCardShowsTheXLabelledHide(layout: SidebarUpdateCardLayout) {
        _ = NSApplication.shared
        let card = SidebarCardFeed.updateCard(UpdateReadyCard(version: "nightly 200", isInstalling: false, automaticUpdates: true,
                                                              notes: UpdateReadyNotes(version: "nightly 200", notes: nil, fullNotesURL: nil)))
        let view = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: Self.width, height: SidebarUpdateCardView.height(for: card, layout: layout)))
        view.layoutOverride = layout
        view.configure(card)
        view.layoutSubtreeIfNeeded()
        #expect(!view.closeButton.isHidden, "\(layout): the Update Ready card shows no x")
        #expect(shownTextButtons(in: view).isEmpty, "\(layout): the Update Ready card still shows a text button")
        #expect(view.closeButton.accessibilityLabel() == "Hide")
        #expect(view.closeButton.themedToolTip == "Hide")
        let close = view.closeButton.frame, title = view.titleLabel.frame
        expectCenteredOnTitle(close, title, font: view.titleLabel.font ?? .systemFont(ofSize: 13), "Update Ready \(layout)")
        #expect(close.maxY <= view.button.frame.minY, "\(layout): the x \(close) overlaps the Restart button \(view.button.frame)")
    }
}
