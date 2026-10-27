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
            .isEmpty)
    }

    @Test func previewHeaderSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtHeader: .preview)
            == ["thought-header": "preview"])
    }

    @Test func liveViewportIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.liveThoughtViewport.descriptor.key == "agentPane.debug.liveThoughtViewport")
        #expect(AgentPaneTunables.liveThoughtViewport.defaultValue == true)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: true)
            .isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, liveThoughtViewport: false)
            == ["live-thought-viewport": "off"])
    }

    /// A mouse wheel's notch glides the transcript (webviews acpmux/wheelGlide.ts) by default, which
    /// sets no attribute; off, `data-wheel-glide="off"`.
    @Test func wheelGlideIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.wheelGlide.descriptor.key == "agentPane.debug.wheelGlide")
        #expect(AgentPaneTunables.wheelGlide.defaultValue == true)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.wheelGlide" })
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, wheelGlide: true).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, wheelGlide: false)
            == ["wheel-glide": "off"])
    }

    /// The turn preview card (webviews conversation/PreviewCard.tsx) is off by default and sets no
    /// attribute; on, `data-turn-preview-cards="on"`.
    @Test func turnPreviewCardsAreOffByDefaultAndOnSetsTheirAttribute() {
        #expect(AgentPaneTunables.turnPreviewCards.descriptor.key == "agentPane.debug.turnPreviewCards")
        #expect(AgentPaneTunables.turnPreviewCards.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.turnPreviewCards" })
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, turnPreviewCards: true)
            == ["turn-preview-cards": "on"])
    }

    /// A streaming reply grows by whole words (webviews conversation/RevealedMarkdown.tsx) by
    /// default, which sets no attribute; off, `data-stream-words="off"`.
    @Test func streamWordsIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.streamWords.descriptor.key == "agentPane.debug.streamWords")
        #expect(AgentPaneTunables.streamWords.defaultValue == true)
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.streamWords" })
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, streamWords: true).isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, streamWords: false)
            == ["stream-words": "off"])
    }

    /// On by default, setting nothing; off sets `data-fold-long-thoughts="off"`.
    @Test func foldIsOnByDefaultAndOffSetsItsAttribute() {
        #expect(AgentPaneTunables.foldLongThoughts.descriptor.key == "agentPane.debug.foldLongThoughts")
        #expect(AgentPaneTunables.foldLongThoughts.defaultValue == true)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default)
            == ["fold-long-thoughts": "off"])
    }

    /// Every finished thought folds by default (Leo 2026-10-20); the older tall-only folds set
    /// their attribute.
    @Test func thresholdDefaultsToEveryThoughtAndTheTallChoicesSetTheirAttribute() {
        #expect(AgentPaneThoughtFoldThreshold.allCases.map(\.rawValue) == ["every", "viewport", "codex"])
        #expect(AgentPaneTunables.thoughtFoldThreshold.descriptor.key == "agentPane.debug.thoughtFoldThreshold")
        #expect(AgentPaneTunables.thoughtFoldThreshold.defaultValue == .every)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .every)
            .isEmpty)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .viewport)
            == ["thought-fold-threshold": "viewport"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, thoughtFoldThreshold: .codex)
            == ["thought-fold-threshold": "codex"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtFoldThreshold" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtHeader" })
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.liveThoughtViewport" })
    }
}
