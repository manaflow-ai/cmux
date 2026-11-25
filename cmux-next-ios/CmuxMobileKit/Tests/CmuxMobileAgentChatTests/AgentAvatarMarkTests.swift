#if os(iOS)
import CmuxMobileDesign
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The round avatar every surface draws (`AgentAvatarMark`): an agent with a mark in
/// design/agent-icons draws it on a circle tinted with its color; any other harness keeps its symbol.
@MainActor @Suite struct AgentAvatarMarkTests {
    @Test func claudeAndCodexDrawTheirOwnMarks() {
        let claude = AgentAvatarMark.rendered(harness: "claude", side: 40, scale: 3)
        let codex = AgentAvatarMark.rendered(harness: "codex", side: 40, scale: 3)
        #expect(claude.isMark && codex.isMark)
        // Half the circle, at the screen's scale, never a template (the owner's colors stay).
        #expect(claude.light?.size == CGSize(width: 20, height: 20))
        #expect(claude.light?.scale == 3)
        #expect(claude.light?.renderingMode == .alwaysOriginal)
        #expect(claude.light?.pngData() != codex.light?.pngData())
    }

    @Test func aProfileIdDrawsItsFamilysMark() {
        #expect(AgentAvatarMark.spec(harness: "claude-sr2", side: 40) == AgentAvatarMark.spec(harness: "claude", side: 40))
        #expect(AgentAvatarMark.rendered(harness: "claude-sr2", side: 40, scale: 3).isMark)
    }

    @Test func theCircleIsTintedWithTheMarksColor() throws {
        let claude = AgentAvatarMark.rendered(harness: "claude", side: 40, scale: 3)
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        claude.fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        // Claude's clay (#D97757), softly.
        #expect(abs(r - 0xD9 / 255.0) < 0.01 && abs(g - 0x77 / 255.0) < 0.01 && abs(b - 0x57 / 255.0) < 0.01)
        #expect(abs(a - 0.12) < 0.001)
        claude.fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(a - 0.22) < 0.001)
        // The Codex mark is black or white only: so is its circle's tint, and the mark differs by appearance.
        let codex = AgentAvatarMark.rendered(harness: "codex", side: 40, scale: 3)
        codex.fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == g && g == b && r < 0.01)
        codex.fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == g && g == b && r > 0.99)
        #expect(codex.light?.pngData() != codex.dark?.pngData())
    }

    @Test func aHarnessWithNoMarkKeepsItsSymbolOnTheRaisedCircle() {
        let terminal = AgentAvatarMark.rendered(harness: "terminal", side: 40, scale: 3)
        #expect(!terminal.isMark)
        #expect(terminal.fill == UIColor.cmuxMobileSurfaceRaised)
        #expect(terminal.light?.isSymbolImage == true)
        #expect(AgentAvatarMark.fallbackSymbol("terminal") == "terminal")
        #expect(AgentAvatarMark.fallbackSymbol("lint-bot") == "sparkle")
        #expect(!AgentAvatarMark.rendered(harness: "lint-bot", side: 40, scale: 3).isMark)
    }

    @Test func aHarnessIsDrawnOnceThenShared() {
        let first = AgentAvatarMark.rendered(harness: "claude", side: 40, scale: 3)
        let second = AgentAvatarMark.rendered(harness: "claude", side: 40, scale: 3)
        #expect(first.light === second.light && first.dark === second.dark)
    }
}
#endif
