#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing
import UIKit

@Suite @MainActor struct TranscriptRenderingRegressionTests {
    @Test func chromePassesBackgroundTouchesToTranscript() {
        let chrome = TranscriptChromePassthroughView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let control = UIButton(frame: CGRect(x: 220, y: 520, width: 60, height: 44))
        chrome.addSubview(control)

        #expect(chrome.hitTest(CGPoint(x: 40, y: 200), with: nil) == nil)
        #expect(chrome.hitTest(CGPoint(x: 240, y: 540), with: nil) === control)
    }

    @Test(arguments: [800.0, 500.0])
    func bottomChromePassthroughTracksKeyboardTop(keyboardTop: CGFloat) {
        let frame = TranscriptChromePassthroughView.bottomPassthroughFrame(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 800),
            keyboardTop: keyboardTop,
            height: 120
        )

        #expect(frame.minY == keyboardTop - 120)
        #expect(frame.maxY == keyboardTop)
    }

    @Test func liveContainerPassesBottomChromeTouchesThroughItsRoot() {
        let container = TranscriptLiveContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0
        )
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        container.setBottomChromeHeight(120)
        container.view.setNeedsLayout()
        container.view.layoutIfNeeded()

        let bandPoint = CGPoint(x: 195, y: 700)
        let backgroundPoint = CGPoint(x: 20, y: 200)
        #expect(container.view.hitTest(bandPoint, with: nil) == nil)
        #expect(container.view.hitTest(backgroundPoint, with: nil) == nil)
    }

    @Test func liveThemeGenerationRecolorsMountedListWithoutLosingAnchor() {
        let initial = AgentGUITheme(terminalTheme: .monokai)
        var terminalTheme = TerminalTheme.monokai
        terminalTheme.background = "#101820"
        terminalTheme.foreground = "#e8f0f8"
        let replacement = AgentGUITheme(terminalTheme: terminalTheme)
        let container = TranscriptLiveContainerViewController(
            theme: initial,
            terminalThemeGeneration: 4
        )
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let entries = (1...40).map { seq in
            EntrySnapshot(
                journalID: JournalID(rawValue: "live-theme"),
                seq: EntrySeq(rawValue: seq),
                kind: EntryKind.agentProse,
                content: EntryContent(
                    contentHash: seq,
                    payload: .agentProse(AgentProsePayload(markdown: "Answer \(seq)"))
                ),
                version: EntityVersion(rawValue: UInt64(seq))
            )
        }
        container.apply(input: TranscriptProjectionInput(entries: entries))
        container.view.layoutIfNeeded()
        container.transcript.collectionView.layoutIfNeeded()
        container.transcript.collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        let list = container.transcript
        let collection = list.collectionView!
        let offset = collection.contentOffset

        container.apply(theme: replacement, terminalThemeGeneration: 5)

        #expect(container.transcript === list)
        #expect(container.transcript.collectionView === collection)
        #expect(collection.contentOffset == offset)
        #expect(container.terminalThemeGeneration == 5)
        #expect(list.currentTheme == replacement)
    }

    @Test func tallFixtureAndBurstAppendImmediatelyUpdateProjection() {
        let model = TranscriptDemoModel()

        model.setTallFixtureEnabled(true)
        #expect(model.input.entries.count == 220)

        model.appendBurstRows()
        #expect(model.input.entries.count == 225)
    }

    @Test func themeReplacementKeepsMountedListCellAndScrollPosition() throws {
        let initial = AgentGUITheme(terminalTheme: .monokai)
        let replacementTheme = TerminalTheme(
            background: "#101820",
            foreground: "#e8f0f8",
            cursor: "#e8f0f8",
            selectionBackground: "#304050",
            selectionForeground: "#e8f0f8",
            palette: TerminalTheme.monokai.palette
        )
        let replacement = AgentGUITheme(terminalTheme: replacementTheme)
        let controller = TranscriptListViewController(theme: initial)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let journal = JournalID(rawValue: "theme-test")
        let entries = (1...40).map { seq in
            let payload: EntryPayload = seq.isMultiple(of: 2)
                ? .agentProse(AgentProsePayload(markdown: "Answer \(seq)"))
                : .userMessage(UserMessagePayload(text: "Prompt \(seq)", attachmentCount: 0, hasImage: false))
            return EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: seq),
                kind: payload.kind,
                content: EntryContent(contentHash: seq, payload: payload),
                version: EntityVersion(rawValue: UInt64(seq))
            )
        }
        controller.apply(input: TranscriptProjectionInput(entries: entries))
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
        controller.collectionView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        controller.collectionView.layoutIfNeeded()
        let collection = controller.collectionView!
        let cell = collection.visibleCells.first
        let offset = collection.contentOffset

        controller.apply(theme: replacement)

        #expect(controller.collectionView === collection)
        #expect(cell == nil || controller.collectionView.visibleCells.contains { $0 === cell })
        #expect(controller.collectionView.contentOffset == offset)
        #expect(controller.currentTheme == replacement)
        #expect(controller.pillHost?.rootView.theme == replacement)
    }
}
#endif
