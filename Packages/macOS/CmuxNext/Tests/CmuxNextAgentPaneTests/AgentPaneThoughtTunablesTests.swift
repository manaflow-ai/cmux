import Testing
@testable import CmuxNextAgentPane

/// The thought tunables (webviews conversation/ThoughtRow.tsx): each default sets no `<html>`
/// attribute, so the page draws its default; another choice sets its own `data-*` attribute.
struct AgentPaneThoughtTunablesTests {
    @Test func headerDefaultsToTheDurationAndSetsNoAttribute() {
        #expect(AgentPaneThoughtHeader.allCases.map(\.rawValue) == ["duration", "preview"])
        #expect(AgentPaneTunables.thoughtHeader.descriptor.key == "agentPane.debug.thoughtHeader")
        #expect(AgentPaneTunables.thoughtHeader.value == .duration)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtHeader: .duration)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["fold-long-thoughts": "on"])
    }

    @Test func previewHeaderSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtHeader: .preview)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["fold-long-thoughts": "on", "thought-header": "preview"])
    }

    @Test func liveViewportIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.liveThoughtViewport.descriptor.key == "agentPane.debug.liveThoughtViewport")
        #expect(AgentPaneTunables.liveThoughtViewport.value)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: true)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["fold-long-thoughts": "on"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: false)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["fold-long-thoughts": "on", "live-thought-viewport": "off"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtHeader" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.liveThoughtViewport" })
    }
}
