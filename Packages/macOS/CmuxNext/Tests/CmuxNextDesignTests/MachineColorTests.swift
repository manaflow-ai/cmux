@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A machine keeps one color everywhere: MachineColor picks AgentPresenceColor's accent for the
/// trimmed, lowercased name, the same pick the agent pane's machineColor.ts makes (its test pins
/// the same names), so the sidebar and the composer chip agree. A color the person picked
/// (`appearance.machineColors`) wins over that pick.
@MainActor @Suite struct MachineColorTests {
    private let tokens = ThemeTokens.derive(from: .ghosttyDefault)

    @Test func matchesTheAgentPanePick() {
        let order = AgentPresenceColor.order
        #expect(order[AgentPresenceColor.index(forKey: "big-red", count: order.count)] == .purple)
        #expect(order[AgentPresenceColor.index(forKey: "air-blue", count: order.count)] == .pink)
        #expect(order[AgentPresenceColor.index(forKey: "cosmic-gray", count: order.count)] == .orange)
    }

    @Test func ignoresCaseAndSurroundingSpace() {
        #expect(MachineColor(name: " Big-Red ").key == "big-red")
        #expect(MachineColor(name: " Big-Red ").rgb(tokens: tokens, overrides: .none)
            == MachineColor(name: "big-red").rgb(tokens: tokens, overrides: .none))
    }

    @Test func aPickedHexColorWins() throws {
        let picked = try #require(ThemeRGB(cssHex: "#12ab34"))
        let overrides = MachineColorOverrides(["big-red": "#12AB34"])
        #expect(MachineColor(name: "big-red").rgb(tokens: tokens, overrides: overrides) == picked)
        #expect(MachineColor(name: "big-red").rgb(tokens: tokens, overrides: overrides)
            != MachineColor(name: "big-red").rgb(tokens: tokens, overrides: .none))
    }

    @Test func aPickedAccentFollowsTheTheme() {
        // big-red's automatic accent is purple; "cyan" takes the theme's cyan, as an automatic cyan machine draws.
        let overrides = MachineColorOverrides(["big-red": "cyan"])
        #expect(MachineColor(name: "big-red").rgb(tokens: tokens, overrides: overrides)
            == (GroupColor.cyan.themeRGB(tokens) ?? GroupColor.cyan.swatchRGB(tokens)))
    }

    @Test func anUnsetMachineKeepsItsAutomaticColor() {
        let overrides = MachineColorOverrides(["big-red": "#12ab34"])
        let automatic = AgentPresenceColor(key: "air-blue").rgb(tokens: tokens)
        #expect(MachineColor(name: "air-blue").rgb(tokens: tokens, overrides: overrides) == automatic)
        #expect(MachineColor(name: "air-blue").rgb(tokens: tokens, overrides: .none) == automatic)
    }

    @Test func keysAreNormalizedLikeTheName() throws {
        // A key written "  Big-Red " in cmux.json colors the machine shown as "big-red", and back.
        let picked = try #require(ThemeRGB(cssHex: "#12ab34"))
        #expect(MachineColor(name: "big-red").rgb(tokens: tokens, overrides: MachineColorOverrides(["  Big-Red ": "#12ab34"])) == picked)
        #expect(MachineColor(name: " BIG-RED").rgb(tokens: tokens, overrides: MachineColorOverrides(["big-red": "#12ab34"])) == picked)
    }

    @Test func aValueThatIsNoColorIsIgnored() {
        let overrides = MachineColorOverrides(["big-red": "crimson", "air-blue": "#12345", "": "#12ab34"])
        #expect(overrides.isEmpty)
        #expect(MachineColor(name: "big-red").rgb(tokens: tokens, overrides: overrides)
            == AgentPresenceColor(key: "big-red").rgb(tokens: tokens))
    }

    @Test func theStoreRepaintsOnlyOnAChange() {
        let store = ThemeStore()
        let generation = store.generation
        #expect(store.setMachineColors(MachineColorOverrides(["big-red": "cyan"])))
        #expect(store.machineColors == MachineColorOverrides(["Big-Red": "cyan"]))
        #expect(!store.setMachineColors(MachineColorOverrides(["big-red": "cyan"])))
        #expect(store.generation == generation + 1)
    }
}
