import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// The thought tunables (webviews conversation/ThoughtRow.tsx): each default sets no `<html>`
/// attribute, so the page draws its default; another choice sets its own `data-*` attribute.
struct AgentPaneThoughtTunablesTests {
    @Test func headerDefaultsToTheDurationAndSetsNoAttribute() {
        #expect(AgentPaneThoughtHeader.allCases.map(\.rawValue) == ["duration", "preview"])
        #expect(AgentPaneTunables.thoughtHeader.descriptor.key == "agentPane.debug.thoughtHeader")
        #expect(AgentPaneTunables.thoughtHeader.defaultValue == .duration)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtHeader: .duration)
            == ["fold-long-thoughts": "on"])
    }

    @Test func previewHeaderSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtHeader: .preview)
            == ["fold-long-thoughts": "on", "thought-header": "preview"])
    }

    @Test func liveViewportIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.liveThoughtViewport.descriptor.key == "agentPane.debug.liveThoughtViewport")
        #expect(AgentPaneTunables.liveThoughtViewport.defaultValue == true)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: true)
            == ["fold-long-thoughts": "on"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: false)
            == ["fold-long-thoughts": "on", "live-thought-viewport": "off"])
    }

    @Test func foldIsOnByDefault() {
        #expect(AgentPaneTunables.foldLongThoughts.descriptor.key == "agentPane.debug.foldLongThoughts")
        #expect(AgentPaneTunables.foldLongThoughts.defaultValue == true)
    }

    @Test func thresholdDefaultsToEveryThoughtAndTheOthersSetTheirAttribute() {
        #expect(AgentPaneThoughtFoldThreshold.allCases.map(\.rawValue) == ["every", "viewport", "codex"])
        #expect(AgentPaneTunables.thoughtFoldThreshold.descriptor.key == "agentPane.debug.thoughtFoldThreshold")
        #expect(AgentPaneTunables.thoughtFoldThreshold.defaultValue == .every)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .every)
            == ["fold-long-thoughts": "on"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .viewport)
            == ["fold-long-thoughts": "on", "thought-fold-threshold": "viewport"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .codex)
            == ["fold-long-thoughts": "on", "thought-fold-threshold": "codex"])
    }

    @Test func workedForListsEveryStepByDefaultAndTheFoldSetsItsAttribute() {
        #expect(AgentPaneTunables.workedForFoldsRuns.descriptor.key == "agentPane.debug.workedForFoldsRuns")
        #expect(AgentPaneTunables.workedForFoldsRuns.defaultValue == false)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, workedForFoldsRuns: true)
            == ["worked-for-runs": "fold"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtFoldThreshold" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtHeader" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.liveThoughtViewport" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.workedForFoldsRuns" })
    }
}
