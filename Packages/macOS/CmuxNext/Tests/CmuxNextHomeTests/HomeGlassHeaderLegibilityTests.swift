import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// The glass header must read as live chrome (lane 16 screenshot
/// home-native-light.png): the name pill's title is dark on a light theme,
/// never the gray of a disabled control, and the glass carries an opaque
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

    /// The darkest luminance drawn inside `rect` of `view`.
    static func darkestLuminance(_ view: NSView, in rect: NSRect) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        var darkest: CGFloat = 1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                darkest = min(darkest, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        return darkest
    }

    @Test func theNamePillTitleIsDarkOnALightTheme() throws {
        let (window, view) = Self.header()
        defer { window.close() }
        let pill = view.header.name
        #expect(!pill.frame.isEmpty)
        let darkest = try Self.darkestLuminance(pill, in: pill.bounds)
        #expect(darkest < 0.35, "the pill title draws like a disabled control (darkest luminance \(darkest))")
    }

    @Test func theGlassCarriesAPageColouredVeil() {
        let (window, view) = Self.header()
        defer { window.close() }
        let alpha = view.header.glass.tintColor?.alphaComponent ?? 0
        #expect(alpha >= 0.7, "rows under the header show through as blurred text (veil alpha \(alpha))")
    }
}
