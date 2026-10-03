import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// The glass header must read as live chrome (lane 16 screenshot
/// home-native-light.png): the name pill's title contrasts with the header
/// in every theme, never the gray of a disabled control, and the glass carries an opaque
/// enough veil of the page colour that rows scrolled under it do not show
/// through as blurred text.
@MainActor
@Suite struct HomeGlassHeaderLegibilityTests {
    static func header() -> (NSWindow, HomeNativeTranscriptView) {
        let me = ParticipantID("user_me")
        let chief = ParticipantID("agent_chief")
        let id = ConversationID("conv_legible")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let participants = [Participant(id: me, kind: .human, displayName: "Me"),
                            Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let summary = ConversationSummary(id: id, participants: participants, createdAt: start, updatedAt: start, readCursors: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.update(items: [], summary: summary, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        view.viewDidChangeEffectiveAppearance()
        return (window, view)
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio of two opaque colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The pill title is the theme's primary text on the page-coloured veil,
    /// in every theme, so it never reads as a disabled control.
    @Test func theNamePillTitleContrastsWithTheVeil() throws {
        let (window, view) = Self.header()
        defer { window.close() }
        #expect(!view.header.namePill.frame.isEmpty)
        let veil = try #require(view.header.glass.tintColor?.withAlphaComponent(1))
        let title = try #require(view.header.name.textColor)
        let ratio = Self.contrast(title, veil)
        #expect(ratio >= 4.5, "the pill title is \(ratio):1 against the header")
    }

    @Test func theGlassCarriesAPageColouredVeil() {
        let (window, view) = Self.header()
        defer { window.close() }
        let alpha = view.header.glass.tintColor?.alphaComponent ?? 0
        #expect(alpha >= 0.7, "rows under the header show through as blurred text (veil alpha \(alpha))")
    }
}
