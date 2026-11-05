import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The Codex-like status icon set (Leo's team, 2026-10-14: "they like Codex's sidebar"): work spins
/// in a neutral grey on the shared spinner, a still ring when nothing may move; done is Codex's blue
/// dot; waiting is a muted line symbol; only an error is red.
@MainActor struct CodexStatusIconSetTests {
    private static let colors = StatusIndicatorLayer.Colors(
        loading: CGColor(gray: 0.6, alpha: 1), attention: CGColor(gray: 0.7, alpha: 1),
        danger: CGColor(srgbRed: 1, green: 0.4, blue: 0.39, alpha: 1), success: CGColor(gray: 0.8, alpha: 1),
        accent: CGColor(gray: 1, alpha: 1))

    private static func plan(_ state: StatusIndicatorState, animates: Bool = true) -> StatusIndicatorPlan {
        StatusIndicatorPlan.make(state, style: .arc, animates: animates, set: .codex)
    }

    @Test func codexIsTheDefaultSetForEveryone() {
        // Leo 2026-10-14, a team decision: the Codex-like icons are the default; the others stay as Debug alternates.
        #expect(StatusIconSet.tunable.defaultValue == .codex)
    }

    @Test func workSpinsInAGreyAndStandsStillAsARing() {
        let spinning = Self.plan(.working)
        #expect(spinning.glyph == .arc && spinning.animation == .spin && spinning.tint == .spinner)
        let still = Self.plan(.working, animates: false)
        #expect(still.glyph == .mark(.vector(.idle)) && still.animation == nil && still.tint == .spinner)
        // The grey is the theme's foreground at Codex's 66%, not a hue.
        let grey = Self.colors.color(for: .spinner)
        #expect(abs(grey.alpha - 0.66) < 0.001 && grey.components?.first == 1)
    }

    @Test func aStillLoaderStaysAStoppedArcNotTheWorkRing() {
        // Loading (a page or a command) keeps the default loading drawing; only agent work stands still as a ring.
        let loader = Self.plan(.busy, animates: false)
        #expect(loader.glyph == .arc && loader.animation == nil && loader.tint == .loading)
    }

    @Test func doneIsCodexsBlueDotAndOnlyAnErrorIsRed() {
        #expect(Self.plan(.success) == StatusIndicatorPlan(glyph: .mark(.vector(.dot)), animation: nil, tint: .unread))
        let blue = Self.colors.color(for: .unread).components ?? []
        #expect(blue.map { ($0 * 255).rounded() } == [57, 130, 245, 255])
        #expect(Self.plan(.error) == StatusIndicatorPlan(glyph: .mark(.vector(.info)), animation: nil, tint: .danger))
        #expect(Self.plan(.waiting(kind: .permission)) == StatusIndicatorPlan(glyph: .mark(.vector(.shieldLine)), animation: nil, tint: .loading))
        #expect(Self.plan(.idle) == .hidden)
    }

    @Test(arguments: [StatusBlockedKind?.none, .question])
    func waitingOnYouDrawsTheSharedDotNotATalkBubble(_ kind: StatusBlockedKind?) {
        // Lawrence 2026-10-20: "rm the talk icon" (the grey speech bubble beside the work spinner in
        // tabs, sidebar rows and group headers). Waiting on you keeps the one existing dot shape, in
        // the attention tint so it reads apart from done's blue dot; no new glyph.
        let plan = Self.plan(.waiting(kind: kind))
        #expect(plan.glyph != .mark(.vector(.waiting)), "the talk bubble is back")
        #expect(plan == StatusIndicatorPlan(glyph: .mark(.vector(.dot)), animation: nil, tint: .attention))
        #expect(Self.plan(.waiting(kind: kind), animates: false) == plan)
    }
}
