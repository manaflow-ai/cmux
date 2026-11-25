import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Session Info behind Debug Settings `agent.sessionInfo` (on by default): the page learns the
/// toggle from the header state (wire name `inspector`), so with it off the header has no Session Info toggle and
/// the summary card comes back (webviews/src/agent-session/acpmux/session-info/SessionInfo.tsx).
@Suite(.serialized)
@MainActor
struct AgentPaneSessionInfoHeaderTests {
    private func withSessionInfo(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.sessionInfo.descriptor])
        TunableStore.shared.set(AgentPaneTunables.sessionInfo.key, on.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.sessionInfo.key, nil) }
        try body()
    }

    /// The toggle was `agent.inspector`: a Debug Settings file that still holds it keeps its choice,
    /// and the new key wins when both are set.
    @Test(arguments: [(#""agent.inspector": false"#, false), (#""agent.inspector": true"#, true),
                      (#""agent.inspector": false, "agent.sessionInfo": true"#, true)])
    func theOldKeyKeepsItsChoice(values: String, expected: Bool) throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "session-info-\(UUID().uuidString).json")
        try Data(("{\"version\": 1, \"values\": {" + values + "}}").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TunableStore()
        store.register([AgentPaneTunables.sessionInfo.descriptor])
        AgentPaneTunables.registerRenames(store)
        store.activate(file: file)
        #expect(store.settledOverride(AgentPaneTunables.sessionInfo.key) == .bool(expected))
    }

    @Test func onByDefaultThePageIsToldToOfferSessionInfo() {
        withSessionInfo(nil) {
            #expect(AgentPaneTunables.sessionInfo.value == true)
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(true))
        }
    }

    @Test func offThePageIsToldThereIsNoSessionInfo() {
        withSessionInfo(false) {
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(false))
        }
    }
}
