import AppKit
import CmuxNextCompat
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// `appearance.agentGlow`: the backdrop stays calm while agents idle, washes while one works and
/// glows in its machine's color while one waits on the person; the view draws nothing while calm.
@MainActor
@Suite struct BackdropAgentGlowTests {
    private static let red = ThemeRGB(hex: 0xFF0000)
    private static let blue = ThemeRGB(hex: 0x0000FF)
    private static func color(_ machine: String) -> ThemeRGB { machine == "my-vm" ? red : blue }

    @Test func noAgentsOrIdleOnesAreCalm() {
        #expect(BackdropAgentGlow(agents: [], color: Self.color) == .calm)
        #expect(BackdropAgentGlow(agents: [.init(machine: "my-vm", level: .calm)], color: Self.color) == .calm)
        #expect(BackdropAgentGlow.calm.opacity == 0)
        #expect(BackdropAgentGlow.calm.color == nil)
    }

    @Test func aWaitingAgentOutranksWorkingOnesAndTakesItsMachinesColor() {
        let glow = BackdropAgentGlow(agents: [.init(machine: "huge-blue", level: .working),
                                              .init(machine: "my-vm", level: .needsYou)], color: Self.color)
        #expect(glow.level == .needsYou)
        #expect(glow.color == Self.red)
        #expect(glow.opacity == 1)
    }

    @Test func aWorkingAgentWashesFaintly() {
        let glow = BackdropAgentGlow(agents: [.init(machine: "huge-blue", level: .working)], color: Self.color)
        #expect(glow.level == .working)
        #expect(glow.color == Self.blue)
        #expect(glow.opacity > 0 && glow.opacity < 1)
    }

    /// The hue holds still while the same agents wait, whatever order the stores list them in.
    @Test func theHueDoesNotDependOnOrder() {
        let agents: [BackdropAgentGlow.Agent] = [.init(machine: "huge-blue", level: .needsYou), .init(machine: "my-vm", level: .needsYou)]
        let glow = BackdropAgentGlow(agents: agents, color: Self.color)
        #expect(glow == BackdropAgentGlow(agents: agents.reversed(), color: Self.color))
        #expect(glow.color == Self.red)
    }

    @Test func theViewIsHiddenWhileCalmAndShowsAGlow() {
        let view = BackdropAgentGlowView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        #expect(view.isHidden)
        view.show(BackdropAgentGlow(level: .needsYou, color: Self.red), fades: false)
        #expect(!view.isHidden)
        #expect(view.layer?.sublayers?.first?.opacity == 1)
        view.show(.calm, fades: false)
        #expect(view.isHidden)
    }

    /// The view follows the design settings' glow: it shows when an agent waits, hides when calm.
    @Test func theViewFollowsTheDesignSettings() async throws {
        let design = DesignSettings()
        let view = BackdropAgentGlowView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.follow(design)
        #expect(view.isHidden)
        let waiting = BackdropAgentGlow(level: .needsYou, color: Self.blue)
        design.agentGlow = waiting
        try await waitUntil { view.shown == waiting }
        #expect(!view.isHidden)
        design.agentGlow = .calm
        try await waitUntil { view.shown == .calm }
        #expect(view.isHidden)
    }

    /// Turns the main actor until `condition` holds (the stream delivers on a later turn).
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            #expect(ContinuousClock.now < deadline, "timed out")
            if ContinuousClock.now >= deadline { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5)) // test harness: the stream hops to the main actor
        }
    }

    /// A pane's backdrop (no active look) never follows the agents; only a window's own does.
    @Test func aPanesBackdropStaysCalm() async throws {
        let design = DesignSettings.shared
        let saved = design.agentGlow
        defer { design.agentGlow = saved }
        let pane = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        // A window's own backdrop (it has an active look) follows, as the control.
        let window = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), images: .shared,
                                        activeLook: ActiveLookScope())
        let waiting = BackdropAgentGlow(level: .needsYou, color: Self.red)
        design.agentGlow = waiting
        try await waitUntil { window.agentGlowView.shown == waiting }
        #expect(!window.agentGlowView.isHidden)
        #expect(pane.agentGlowView.isHidden)
        #expect(pane.agentGlowView.shown == .calm)
    }
}
