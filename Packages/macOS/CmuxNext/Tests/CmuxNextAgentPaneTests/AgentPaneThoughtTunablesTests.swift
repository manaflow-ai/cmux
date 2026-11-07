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
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, thoughtHeader: .duration)
            .isEmpty)
    }

    @Test func previewHeaderSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, thoughtHeader: .preview)
            == ["thought-header": "preview"])
    }

    /// The turn preview card (webviews conversation/PreviewCard.tsx) is off by default and sets no
    /// attribute; on, `data-turn-preview-cards="on"`.
    @Test func turnPreviewCardsAreOffByDefaultAndOnSetsTheirAttribute() {
        #expect(AgentPaneTunables.turnPreviewCards.descriptor.key == "agentPane.debug.turnPreviewCards")
        #expect(AgentPaneTunables.turnPreviewCards.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.turnPreviewCards" })
        #expect(AgentPaneTunables.attributes(topStripStyle: .default).isEmpty)
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, turnPreviewCards: true)
            == ["turn-preview-cards": "on"])
    }

    /// Every finished thought folds by default (Leo 2026-10-20); the older tall-only folds set
    /// their attribute.
    @Test func thresholdDefaultsToEveryThoughtAndTheTallChoicesSetTheirAttribute() {
        #expect(AgentPaneThoughtFoldThreshold.allCases.map(\.rawValue) == ["every", "viewport", "codex"])
        #expect(AgentPaneTunables.thoughtFoldThreshold.descriptor.key == "agentPane.debug.thoughtFoldThreshold")
        #expect(AgentPaneTunables.thoughtFoldThreshold.defaultValue == .every)
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, thoughtFoldThreshold: .every)
            .isEmpty)
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, thoughtFoldThreshold: .viewport)
            == ["thought-fold-threshold": "viewport"])
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, thoughtFoldThreshold: .codex)
            == ["thought-fold-threshold": "codex"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtFoldThreshold" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtHeader" })
    }

    /// The fold, the live viewport, word streaming and wheel glide always run; their Debug switches
    /// are gone (Leo 2026-11-05).
    @Test func theRemovedSwitchesAreNotListed() {
        let removed: Set = [
            "agentPane.debug.foldLongThoughts", "agentPane.debug.liveThoughtViewport",
            "agentPane.debug.streamWords", "agentPane.debug.wheelGlide",
        ]
        #expect(!AgentPaneTunables.all.contains { removed.contains($0.key) })
    }
}
