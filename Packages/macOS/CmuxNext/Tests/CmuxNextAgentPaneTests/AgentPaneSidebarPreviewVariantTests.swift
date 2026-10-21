import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.sidebarPreviewVariant` is a native baseline for the page's sidebar preview;
/// a user's `layout.sidebarPreviewVariant` can still override it for a prototype.
struct AgentPaneSidebarPreviewVariantTests {
    @Test func offersCardQuietAndOutlineWithCardAsTheDefault() {
        #expect(AgentPaneSidebarPreviewVariant.allCases.map(\.rawValue) == ["card", "quiet", "outline"])
        #expect(AgentPaneTunables.sidebarPreviewVariant.descriptor.key == "agentPane.debug.sidebarPreviewVariant")
        #expect(AgentPaneTunables.sidebarPreviewVariant.value == .card)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.sidebarPreviewVariant" })
    }

    @Test func eventCarriesTheNativeChoiceToThePage() {
        #expect(AgentPageEvent.sidebarPreviewVariant(.quiet).value.stringValue == "quiet")
    }
}
