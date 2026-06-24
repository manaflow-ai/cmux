import CmuxSessionIndex
import Testing

@testable import CmuxSessionIndexUI

/// Behavior tests for `AgentIconImage`'s value identity, which drives SwiftUI's
/// `Equatable`-gated re-render skipping in the session-index list rows.
struct AgentIconImageTests {
    @Test("Identical presentation values compare equal")
    func equalForIdenticalInputs() {
        let lhs = AgentIconImage(assetName: "AgentIcons/Claude", systemImageName: nil, size: 14)
        let rhs = AgentIconImage(assetName: "AgentIcons/Claude", systemImageName: nil, size: 14)
        #expect(lhs == rhs)
    }

    @Test("A different asset name compares unequal")
    func unequalForDifferentAsset() {
        let lhs = AgentIconImage(assetName: "AgentIcons/Claude", systemImageName: nil, size: 14)
        let rhs = AgentIconImage(assetName: "AgentIcons/Codex", systemImageName: nil, size: 14)
        #expect(lhs != rhs)
    }

    @Test("A different size compares unequal")
    func unequalForDifferentSize() {
        let lhs = AgentIconImage(assetName: nil, systemImageName: "person.crop.circle", size: 12)
        let rhs = AgentIconImage(assetName: nil, systemImageName: "person.crop.circle", size: 14)
        #expect(lhs != rhs)
    }

    @Test("Symbol-fallback inputs compare equal")
    func equalForSymbolFallback() {
        let lhs = AgentIconImage(assetName: nil, systemImageName: nil, size: 12)
        let rhs = AgentIconImage(assetName: nil, systemImageName: nil, size: 12)
        #expect(lhs == rhs)
    }

    @Test("Built from a SessionAgent's raw value, the icon is stable across equal inputs")
    func stableAcrossSessionAgentRawValue() {
        let agent = SessionAgent.claude
        let lhs = AgentIconImage(assetName: agent.rawValue, systemImageName: nil, size: 14)
        let rhs = AgentIconImage(assetName: SessionAgent.claude.rawValue, systemImageName: nil, size: 14)
        #expect(lhs == rhs)
    }
}
