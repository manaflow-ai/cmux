// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import CmuxRemoteScreenSharing
import CmuxDeviceHub
import Testing

/// The worker's approval banner draws the cmux dialog card (Lawrence 2026-11-17, "improve this UI, think liquid
/// glass, match all modern parts of our cmux dialogs"): the four answers stacked the card's width, Allow Once first
/// with its Return keycap, Deny last as quiet red text with its Escape keycap, the fingerprint in two lines of four
/// groups on a well. Before, Deny and Allow Once sat on one row and the two Always Allow buttons on another, each at
/// its own width, as system push buttons on a grey popover.
@MainActor
@Suite struct ApprovalBannerLookTests {
    private static func views(under root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + views(under: $0) } }

    @Test func answersStackTheCardsWidthWithOnePrimaryAndAQuietDeny() throws {
        let fingerprint = "78be18e0c08c9c4d7443d95e2db68074" + String(repeating: "ab", count: 16)
        let request = SessionRequest(id: "ask", viewerId: "v", viewerName: "iPhone", viewerKeyFingerprint: fingerprint, scope: .full)
        var answered: [ApprovalChoice] = []
        let view = ApprovalView(request: request, error: nil, enabled: true) { answered.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        let ids = ["once", "alwaysView", "alwaysFull", "deny"]
        let buttons = try ids.map { id in
            try #require(Self.views(under: view).first { $0.accessibilityIdentifier() == "macScreen.approval.\(id)" } as? ApprovalButton, "\(id)")
        }
        let frames = buttons.map { $0.convert($0.bounds, to: nil) }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.maxY <= upper.minY)
            #expect(lower.width == upper.width && lower.minX == upper.minX && lower.height == upper.height)
        }
        #expect(buttons.map(\.role) == [.primary, .secondary, .secondary, .quietDestructive])
        let code = Self.views(under: view).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("\n") }
        #expect(code?.stringValue == "78BE 18E0 C08C 9C4D\n7443 D95E 2DB6 8074")
        #expect(code?.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(view.fittingSize.width == ApprovalView.width)
        buttons[0].performClick(nil)
        buttons[3].performClick(nil)
        #expect(answered == [.once, .deny])
    }

    @Test func aFailedAnswerShowsAndAnsweringDisablesTheButtons() {
        let request = SessionRequest(id: "ask", viewerId: "v", viewerName: "iPhone", scope: .view)
        let view = ApprovalView(request: request, error: "The answer did not reach the device hub. Try again.", enabled: false) { _ in }
        #expect(Self.views(under: view).contains { $0.accessibilityIdentifier() == "macScreen.approval.error" })
        #expect(view.buttons.allSatisfy { !$0.isEnabled })
    }
}
