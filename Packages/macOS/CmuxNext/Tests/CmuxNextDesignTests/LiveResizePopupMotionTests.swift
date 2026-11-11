import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Review of #40387 (follow-up): a popup and a hover card are child windows of the app window
/// that opened them. While that window is in a live resize its movement snaps
/// (`Motion.isLiveResizing` follows `window.parent`), but the popup's shrink and grow and the
/// hover card's morph read the window-free gate, so they still moved on a spring or a curve
/// toward a place that the next frame of the drag replaces. They now ask about their own
/// window. A fade is not movement: it stays. A resize of another window changes nothing.
///
/// A window enters a live resize through AppKit's notification, which a test posts to a private
/// center for its own window. Every test is synchronous.
@MainActor @Suite(.serialized, .closesItsWindows) struct LiveResizePopupMotionTests {
    private static let pivot = CGPoint(x: 150, y: 200)

    /// `body` runs with a tracker on a private center in place of the app's.
    private static func tracked(_ body: (NotificationCenter) throws -> Void) rethrows {
        let center = NotificationCenter()
        let app = LiveResizeWindows.shared
        LiveResizeWindows.shared = LiveResizeWindows(center: center)
        defer { LiveResizeWindows.shared = app }
        try body(center)
    }

    /// Movement and fades animate in the overlays and hover card categories while `body` runs.
    private static func animating(_ body: () throws -> Void) throws {
        let design = DesignSettings.shared
        let old = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        design.animationsEnabled = true
        design.disabledAnimationCategories.remove(.overlays)
        design.disabledAnimationCategories.remove(.hoverCards)
        design.animationSpeed = .fast
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer {
            Motion.reduceMotionOverride = previous
            design.animationsEnabled = old.0
            design.disabledAnimationCategories = old.1
            design.animationSpeed = old.2
        }
        try #require(Motion.overlays.animatesMovement && Motion.hoverCards.animatesMovement, "movement is off on this host")
        try body()
    }

    private static func appWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// A popup panel attached to `parent` as a popup owner attaches it, with its card layer.
    private static func popup(of parent: NSWindow) throws -> (NSPanel, CALayer) {
        let panel = NSPanel(contentRect: NSRect(x: 240, y: 240, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = try #require(panel.contentView)
        content.wantsLayer = true
        let layer = try #require(content.layer)
        parent.addChildWindow(panel, ordered: .above)
        try #require(panel.parent === parent, "AppKit did not attach the popup; the test proves nothing")
        try #require(Motion.canAnimate(in: content), "the popup's window cannot animate on this host; the test proves nothing")
        return (panel, layer)
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func aPopupCloseDoesNotShrinkWhileItsWindowIsInALiveResize() throws {
        try Self.animating {
            let parent = Self.appWindow()
            let (panel, layer) = try Self.popup(of: parent)
            defer { parent.removeChildWindow(panel); panel.closeAfterTest(); parent.closeAfterTest() }
            try Self.tracked { center in
                // Control: with no resize the close shrinks toward its control.
                panel.openPopup(pivot: Self.pivot)
                panel.closePopup(pivot: Self.pivot) {}
                try #require(layer.animation(forKey: "sublayerTransform") != nil, "the close does not shrink on this host; the test proves nothing")
                panel.resetPopupScale()

                center.post(name: NSWindow.willStartLiveResizeNotification, object: parent)
                panel.openPopup(pivot: Self.pivot)
                panel.closePopup(pivot: Self.pivot) {}
                #expect(layer.animation(forKey: "sublayerTransform") == nil, "the popup shrinks on a curve while its window is resized")
                #expect(layer.animation(forKey: "opacity") != nil, "a live resize stops no fade: the close still fades")
                panel.resetPopupScale()
                center.post(name: NSWindow.didEndLiveResizeNotification, object: parent)

                panel.openPopup(pivot: Self.pivot)
                panel.closePopup(pivot: Self.pivot) {}
                #expect(layer.animation(forKey: "sublayerTransform") != nil, "after the resize the close shrinks again")
                panel.resetPopupScale()
            }
        }
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func aTooltipDoesNotGrowInWhileItsWindowIsInALiveResize() throws {
        try Self.animating {
            let parent = Self.appWindow()
            let (panel, layer) = try Self.popup(of: parent)
            defer { parent.removeChildWindow(panel); panel.closeAfterTest(); parent.closeAfterTest() }
            try Self.tracked { center in
                panel.alphaValue = 0
                panel.openTooltipWithEntrance(pivot: Self.pivot)
                try #require(layer.animation(forKey: "sublayerTransform") != nil, "the tooltip does not grow in on this host; the test proves nothing")
                panel.showPopupAtOnce()

                center.post(name: NSWindow.willStartLiveResizeNotification, object: parent)
                panel.alphaValue = 0
                panel.openTooltipWithEntrance(pivot: Self.pivot)
                #expect(layer.animation(forKey: "sublayerTransform") == nil, "the tooltip grows on a spring while its window is resized")
                #expect(CATransform3DIsIdentity(layer.sublayerTransform), "the tooltip is not at its size")
                #expect(panel.alphaValue == 1)
                center.post(name: NSWindow.didEndLiveResizeNotification, object: parent)
            }
        }
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func aResizeOfAnotherWindowDoesNotStopAPopupsShrink() throws {
        try Self.animating {
            let parent = Self.appWindow()
            let other = Self.appWindow()
            let (panel, layer) = try Self.popup(of: parent)
            defer { parent.removeChildWindow(panel); panel.closeAfterTest(); parent.closeAfterTest(); other.closeAfterTest() }
            Self.tracked { center in
                center.post(name: NSWindow.willStartLiveResizeNotification, object: other)
                panel.openPopup(pivot: Self.pivot)
                panel.closePopup(pivot: Self.pivot) {}
                #expect(layer.animation(forKey: "sublayerTransform") != nil, "a resize of another window stops this popup's shrink")
                panel.resetPopupScale()
                center.post(name: NSWindow.didEndLiveResizeNotification, object: other)
            }
        }
    }

    @Test func aHoverCardDoesNotMorphWhileItsWindowIsInALiveResize() throws {
        try Self.animating {
            let parent = Self.appWindow()
            let card = HoverCardPanel()
            defer { card.closeAfterTest(); parent.closeAfterTest() }
            let body = NSView()
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 240), body.heightAnchor.constraint(equalToConstant: 120)])
            let anchor = CGRect(x: parent.frame.minX + 8, y: parent.frame.minY + 40, width: 220, height: 48)
            card.present(body: body, anchor: anchor, placement: .beside, parent: parent, themeAnchor: nil,
                         sliding: false, interactive: true, applyTheme: {})
            try #require(card.parent === parent, "the card is not a child of its window; the test proves nothing")
            // The frame the card had before: a taller card, so a morph has a size to change.
            let previous = card.cardFrame.insetBy(dx: 0, dy: -40)
            Self.tracked { center in
                center.post(name: NSWindow.willStartLiveResizeNotification, object: parent)
                #expect(!card.morph(from: previous), "the card resizes on a spring while its window is resized")
                #expect(card.activeMorph == nil)
                center.post(name: NSWindow.didEndLiveResizeNotification, object: parent)
                // Control, after: the same call morphs when no resize runs, so the false above is the resize.
                #expect(card.morph(from: previous), "the card does not morph on this host; the test proves nothing")
            }
        }
    }
}
