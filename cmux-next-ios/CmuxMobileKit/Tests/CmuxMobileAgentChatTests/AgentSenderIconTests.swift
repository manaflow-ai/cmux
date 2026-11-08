import Testing
@testable import CmuxMobileAgentChat

/// A sender's icon on the phone takes the same tone the Mac gives the same key (agentTones.ts
/// `hashTone`), so a session reads in one color on both, and its family's mark from a harness id.
@MainActor @Suite struct AgentSenderIconTests {
    @Test func toneMatchesTheMacHash() {
        // The Mac's hashTone of the same strings (FNV-1a of the UTF-16 units, modulo five).
        #expect(AgentSenderIcon.hashTone("s-claude-13") == 0)
        #expect(AgentSenderIcon.hashTone("claude-13") == 3)
        #expect(AgentSenderIcon.hashTone("gcp-codex-swarm-08/claude") == 3)
        #expect(AgentSenderIcon.hashTone("lane-a") == 1)
    }

    @Test func tonesAreTheMacsColors() {
        #expect(AgentSenderIcon.toneRGB.count == 5)
        let green = AgentSenderIcon.toneRGB[0]
        #expect(green.0 == 0x3f && green.1 == 0xb9 && green.2 == 0x50)
    }

    @Test func aProfileIdDrawsItsFamilysMark() {
        #expect(AgentSenderIcon.family("claude") == "claude")
        // A profile id the catalog knows ("codex-sol") keeps itself; one it doesn't takes its family.
        #expect(["codex-sol", "codex"].contains(AgentSenderIcon.family("codex-sol")))
        #expect(AgentSenderIcon.family(nil) == nil)
        #expect(AgentSenderIcon.family("") == nil)
    }
}
