import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// The conversation header must read as live chrome: the name contrasts
/// with the header in every theme, never the gray of a disabled control,
/// and the header's page fill is opaque so rows scrolled under it do not
/// show through as blurred text. It draws no glass and no capsule.
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

    /// The name is the theme's primary text on the header's page fill, in
    /// every theme, so it never reads as a disabled control.
    @Test func theNameContrastsWithTheHeader() throws {
        let (window, view) = Self.header()
        defer { window.close() }
        #expect(!view.header.name.frame.isEmpty)
        let page = try #require(view.header.backdrop.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        let title = try #require(view.header.name.textColor)
        let ratio = Self.contrast(title, page)
        #expect(ratio >= 4.5, "the name is \(ratio):1 against the header")
    }

    /// The header is opaque, so rows scrolled under it end at its edge
    /// instead of showing through as blurred text.
    @Test func theHeaderFillIsOpaque() {
        let (window, view) = Self.header()
        defer { window.close() }
        let alpha = view.header.backdrop.layer?.backgroundColor?.alpha ?? 0
        #expect(alpha == 1, "rows under the header show through (fill alpha \(alpha))")
    }

    /// Leo's first-launch capture (op-next-look): a letter in a disc over a
    /// glass capsule read as a placeholder. No glass or capsule draws; the
    /// avatar is a true circle beside the name, centred on one line.
    @Test func theHeaderDrawsNoGlassOrCapsule() {
        let (window, view) = Self.header()
        defer { window.close() }
        let header = view.header
        #expect(!header.subviews.contains { $0 is NSGlassEffectView })
        let disc = header.avatarDisc.frame
        #expect(disc.width == disc.height && header.avatarDisc.layer?.cornerRadius == disc.width / 2, "a true circle")
        #expect(abs(header.name.frame.midY - disc.midY) <= 1, "name \(header.name.frame) beside avatar \(disc)")
        #expect(header.name.frame.minX > disc.maxX)
    }

    /// The Chief's avatar is a glyph on the theme accent, not its initial.
    @Test func theChiefShowsAGlyphNotALetter() {
        let (window, view) = Self.header()
        defer { window.close() }
        #expect(view.header.isChief)
        #expect(!view.header.avatarGlyph.isHidden)
        #expect(view.header.avatar.isHidden)
    }
}
