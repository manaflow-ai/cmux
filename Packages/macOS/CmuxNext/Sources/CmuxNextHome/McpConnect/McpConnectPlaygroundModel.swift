#if DEBUG
import CmuxNextDesign
import Observation

/// DEBUG ONLY: the playground's state. Changing the style, server or phase rebuilds the flow from
/// the start and walks it to the phase.
@MainActor @Observable
final class McpConnectPlaygroundModel {
    var style: McpConnectCardStyle = .factsTable { didSet { rebuild() } }
    var fixture: McpConnectCardFixture = .linear { didSet { rebuild() } }
    var phase: McpConnectPlaygroundPhase = .ask { didSet { rebuild() } }
    private(set) var flow: McpConnectCardFlow
    /// Bumped on every rebuild so the cards drop their local state (an open disclosure, a typed key).
    private(set) var generation = 0

    static let lightTokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF),
                                                                   foreground: ThemeRGB(hex: 0x1D1F21)))
    static let darkTokens = ThemeTokens.fallback
    static let light = McpConnectCardColors(tokens: lightTokens)
    static let dark = McpConnectCardColors(tokens: darkTokens)

    init() {
        flow = McpConnectCardFlow(card: McpConnectCardFixture.linear.card)
    }

    func select(style: McpConnectCardStyle?, fixture: McpConnectCardFixture?, phase: McpConnectPlaygroundPhase?) {
        if let style { self.style = style }
        if let fixture { self.fixture = fixture }
        if let phase { self.phase = phase }
    }

    private func rebuild() {
        var next = McpConnectCardFlow(card: fixture.card)
        phase.apply(to: &next, tools: fixture.tools)
        flow = next
        generation += 1
    }

    func finishSignIn() {
        flow.signedIn()
        flow.connected(fixture.tools)
    }

    var actions: McpConnectCardActions {
        McpConnectCardActions(
            choose: { [weak self] scope in self?.flow.choose(scope) },
            connect: { [weak self] in _ = self?.flow.connect() },
            cancel: { [weak self] in _ = self?.flow.cancel() },
            submitKey: { [weak self] key in _ = self?.flow.submit(key) }
        )
    }
}
#endif
