import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// A Cloud start's questions are one definition shown two ways: in the start's card, or as the cmux
/// dialog they were before where no card holds them. No start asks about a login any more (the
/// machine's agents use the Cloud service's model route), so these cover only the channel.
@MainActor @Suite(.serialized)
struct AgentPaneCloudAskerTests {
    private func ask() -> AgentPaneCloudAsk {
        AgentPaneCloudAsk(id: "ask-1", kind: .firstLogin, title: "Start Claude on paint?", lines: ["One line."],
                          buttons: [.init(id: "cancel", title: "Cancel", role: "cancel"), .init(id: "start", title: "Start", role: "default")])
    }

    @Test func aDialogWithNoScopeAsksNothing() async throws {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let asker = AgentPaneCloudAsker.dialog({ nil }, center: center)
        #expect(await asker.ask(ask()) == nil)
        #expect(center.records.isEmpty)
    }
}
