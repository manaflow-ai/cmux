import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A notice action marked as a switch draws as a small switch with its title on the button row's trailing edge,
/// not as a button; flipping it sends the action (Tidy Up T3: Archive, then an inline "Always" switch).
@MainActor @Suite(.serialized) struct SidebarNoticeCardSwitchTests {
    static let notice = SidebarNoticeCard(
        id: "auto-archive.suggest", title: "2 idle workspaces", lines: ["A", "B"],
        actions: [SidebarNoticeCard.Action(id: "archive", title: "Archive", prominent: true),
                  SidebarNoticeCard.Action(id: "always", title: "Always", isSwitch: true)],
        dismissLabel: "Not Now")

    private func laidOut() -> SidebarNoticeCardView {
        _ = NSApplication.shared
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: Self.notice)))
        card.configure(Self.notice)
        card.layoutSubtreeIfNeeded()
        return card
    }

    @Test func aSwitchActionDrawsAsASwitchRightOfTheButtons() throws {
        let card = laidOut()
        #expect(card.actionButtons.count == 1, "only Archive is a button")
        let toggle = try #require(card.actionSwitch)
        #expect(!toggle.isHidden && toggle.title == "Always" && !toggle.isOn)
        let button = try #require(card.actionButtons.first)
        #expect(toggle.frame.minX > button.frame.maxX, "the switch sits right of Archive")
        #expect(toggle.frame.maxX <= card.bounds.width, "inside the card")
        let title = ("Always" as NSString).size(withAttributes: [.font: Typography.caption]).width
        #expect(toggle.frame.width >= title + 20, "the title shows whole beside the switch (a capture read \"Alw…\")")
    }

    @Test func flippingTheSwitchSendsItsAction() throws {
        let card = laidOut()
        var sent: [(String, String)] = []
        card.onAction = { sent.append(($0, $1)) }
        try #require(card.actionSwitch).flip()
        #expect(sent.count == 1 && sent.first?.0 == "auto-archive.suggest" && sent.first?.1 == "always")
    }

    @Test func aCardWithoutASwitchShowsNone() {
        _ = NSApplication.shared
        let plain = SidebarNoticeCard(id: "tip", title: "Tip", actions: [SidebarNoticeCard.Action(id: "ok", title: "OK", prominent: true)])
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: plain)))
        card.configure(plain)
        card.layoutSubtreeIfNeeded()
        #expect(card.actionSwitch?.isHidden ?? true)
        #expect(card.actionButtons.count == 1)
    }
}
