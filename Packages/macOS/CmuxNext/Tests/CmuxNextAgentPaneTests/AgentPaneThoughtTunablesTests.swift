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

    /// The turn preview card (webviews conversation/PreviewCard.tsx) is off by default and sets no
    /// attribute; on, `data-turn-preview-cards="on"`.
    @Test func turnPreviewCardsAreOffByDefaultAndOnSetsTheirAttribute() {
        #expect(AgentPaneTunables.turnPreviewCards.descriptor.key == "agentPane.debug.turnPreviewCards")
        #expect(AgentPaneTunables.turnPreviewCards.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.turnPreviewCards" })
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, turnPreviewCards: true)
            == ["turn-preview-cards": "on"])
    }

    /// A streaming reply grows by whole words (webviews conversation/RevealedMarkdown.tsx) by
    /// default, which sets no attribute; off, `data-stream-words="off"`.
    @Test func streamWordsIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.streamWords.descriptor.key == "agentPane.debug.streamWords")
        #expect(AgentPaneTunables.streamWords.defaultValue == true)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.streamWords" })
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, streamWords: true).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, streamWords: false)
            == ["stream-words": "off"])
    }

    @Test func foldIsOnByDefault() {
        #expect(AgentPaneTunables.foldLongThoughts.descriptor.key == "agentPane.debug.foldLongThoughts")
        #expect(AgentPaneTunables.foldLongThoughts.defaultValue == true)
    }

    @Test func thresholdDefaultsToTheViewportAndCodexSetsItsAttribute() {
        #expect(AgentPaneThoughtFoldThreshold.allCases.map(\.rawValue) == ["viewport", "codex"])
        #expect(AgentPaneTunables.thoughtFoldThreshold.descriptor.key == "agentPane.debug.thoughtFoldThreshold")
        #expect(AgentPaneTunables.thoughtFoldThreshold.defaultValue == .viewport)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .viewport)
            == ["fold-long-thoughts": "on"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .codex)
            == ["fold-long-thoughts": "on", "thought-fold-threshold": "codex"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtFoldThreshold" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtHeader" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.liveThoughtViewport" })
    }
}
