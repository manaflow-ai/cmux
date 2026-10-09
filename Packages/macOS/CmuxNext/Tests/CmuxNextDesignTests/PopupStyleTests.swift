import AppKit
import Foundation
import Testing
@testable import CmuxNextDesign

/// One look for every native popover and menu (Leo 2026-10-08): the web's
/// popup surface (webviews/src/ui/popupSurface.css, #18729) in AppKit. Same
/// radius and padding tokens, one 12% shadow drawn by the card in a
/// transparent band, never the system window shadow.
@MainActor
@Suite(.serialized)
struct PopupStyleTests {
    /// The web stylesheet the native tokens mirror.
    static func webSurface() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("webviews/src/ui/popupSurface.css"), encoding: .utf8)
    }

    static func number(_ pattern: String, in css: String, group: Int = 1) throws -> CGFloat {
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)))
        let range = try #require(Range(match.range(at: group), in: css))
        return CGFloat(try #require(Double(css[range])))
    }

    @Test func theTokensMatchTheWebPopupSurface() throws {
        let css = try Self.webSurface()
        #expect(PopupStyle.cornerRadius == (try Self.number(#"--ui-popup-radius:\s*(\d+)px"#, in: css)))
        #expect(PopupStyle.padding == (try Self.number(#"--ui-popup-padding:\s*(\d+)px"#, in: css)))
        #expect(PopupStyle.rowHeight == (try Self.number(#"--ui-row-height:\s*(\d+)px"#, in: css)))
        #expect(PopupStyle.rowCornerRadius == (try Self.number(#"--ui-row-radius:\s*(\d+)px"#, in: css)))
        let shadow = #"--ui-popup-shadow:\s*0 (\d+)px (\d+)px color-mix\(in srgb, black (\d+)%"#
        #expect(PopupStyle.shadowOffset == (try Self.number(shadow, in: css, group: 1)))
        #expect(PopupStyle.shadowBlur == (try Self.number(shadow, in: css, group: 2)))
        #expect(abs(PopupStyle.shadowAlpha * 100 - (try Self.number(shadow, in: css, group: 3))) < 0.001)
        #expect(abs(PopupStyle.openDuration * 1000 - Double(try Self.number(#"--ui-popup-open:\s*(\d+)ms"#, in: css))) < 0.001)
    }

    @Test func theShadowIsOneSubtleLayer() {
        let shadow = PopupStyle.shadow()
        #expect(shadow.shadowBlurRadius == PopupStyle.shadowBlur)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -PopupStyle.shadowOffset))
        #expect(shadow.shadowColor?.alphaComponent == PopupStyle.shadowAlpha)
        #expect(PopupStyle.shadowMargin >= PopupStyle.shadowBlur + PopupStyle.shadowOffset)
    }

    /// The hover card: no window shadow; the card casts the popup shadow
    /// into a transparent band, and places by its own frame.
    @Test func theHoverCardIsAPopup() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        let panel = HoverCardPanel()
        #expect(!panel.hasShadow)
        #expect(panel.glass.cornerRadius == PopupStyle.cornerRadius)
        let host = try #require(panel.contentView as? PopupHostView)
        #expect(host.shadowLayer.shadowOpacity == Float(PopupStyle.shadowAlpha))
        let body = NSView()
        body.widthAnchor.constraint(equalToConstant: 200).isActive = true
        body.heightAnchor.constraint(equalToConstant: 80).isActive = true
        panel.present(body: body, anchor: CGRect(x: 200, y: 400, width: 100, height: 30), placement: .below, parent: parent,
                      themeAnchor: nil, sliding: false, applyTheme: {})
        #expect(panel.cardFrame.size == CGSize(width: 200, height: 80))
        #expect(panel.frame == panel.cardFrame.insetBy(dx: -PopupStyle.shadowMargin, dy: -PopupStyle.shadowMargin))
        #expect(panel.cardFrame.minX == 200)
        #expect(host.shadowLayer.shadowPath?.boundingBox == host.card.frame)
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        parent.close()
    }

    /// A window not yet placed (zero size) leaves the card's frame finite.
    @Test func anUnplacedHostKeepsAFiniteCard() {
        let host = PopupHostView(card: NSView())
        host.setFrameSize(.zero)
        host.layoutSubtreeIfNeeded()
        #expect(!host.card.frame.isNull && host.card.frame.minX.isFinite)
    }
}
