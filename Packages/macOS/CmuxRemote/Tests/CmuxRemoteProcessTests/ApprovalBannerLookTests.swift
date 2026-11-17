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
        // SECURITY: an Allow's own press answers nothing (only the person's click does, ``ApprovalPanel``); Deny takes any.
        buttons[0].performClick(nil)
        buttons[3].performClick(nil)
        #expect(answered == [.deny])
        #expect(buttons[0].keycapText == nil, "Allow Once shows no Return key")
        #expect(buttons[3].keycapText == "esc")
    }

    /// SECURITY: Return never allows, after a click into the banner either; Escape denies.
    @Test func returnNeverAllowsEscapeDenies() throws {
        let request = SessionRequest(id: "ask", viewerId: "v", viewerName: "iPhone", scope: .full)
        var answered: [ApprovalChoice] = []
        let view = ApprovalView(request: request, error: nil, enabled: true) { answered.append($0) }
        for code: UInt16 in [36, 76, 53] {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, characters: code == 53 ? "\u{1b}" : "\r",
                                                    charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: code))
            view.keyDown(with: key)
        }
        #expect(answered == [.deny])
    }

    /// SECURITY: only the person's own click on an Allow answers it (the HID system's input, not a posted click
    /// or a press), and not one begun as the banner showed.
    @Test func onlyThePersonsOwnClickAllows() throws {
        let request = SessionRequest(id: "ask", viewerId: "v", viewerName: "iPhone", scope: .full)
        var answered: [ApprovalChoice] = []
        let panel = ApprovalBanner.makePanel()
        defer { panel.close() }
        let view = ApprovalView(request: request, error: nil, enabled: true) { answered.append($0) }
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        panel.onAllow = { answered.append($0) }
        let base = ProcessInfo.processInfo.systemUptime
        panel.shown(at: base)
        let full = try #require(view.buttons.first { $0.accessibilityIdentifier() == "macScreen.approval.alwaysFull" })
        let center = full.convert(NSPoint(x: full.bounds.midX, y: full.bounds.midY), to: nil)
        var number = 0
        var genuine: Set<Int> = []
        panel.isPersonEvent = { genuine.contains($0.eventNumber) }
        var current: NSEvent?
        panel.eventInHand = { current }
        let click = { (at: TimeInterval, person: Bool) throws in
            number += 1
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: [], timestamp: base + at,
                                                       windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
            number += 1
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: [], timestamp: base + at + 0.05,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
            if person { genuine.formUnion([down.eventNumber, up.eventNumber]) }
            current = down
            panel.dispatch(down) { current = up }
        }
        try click(0.01, true) // begun as the banner showed
        try click(10, false) // a click another process posted
        #expect(answered.isEmpty)
        try click(20, true)
        #expect(answered == [.alwaysFull])
    }

    @Test func aFailedAnswerShowsAndAnsweringDisablesTheButtons() {
        let request = SessionRequest(id: "ask", viewerId: "v", viewerName: "iPhone", scope: .view)
        let view = ApprovalView(request: request, error: "The answer did not reach the device hub. Try again.", enabled: false) { _ in }
        #expect(Self.views(under: view).contains { $0.accessibilityIdentifier() == "macScreen.approval.error" })
        #expect(view.buttons.allSatisfy { !$0.isEnabled })
    }
}
