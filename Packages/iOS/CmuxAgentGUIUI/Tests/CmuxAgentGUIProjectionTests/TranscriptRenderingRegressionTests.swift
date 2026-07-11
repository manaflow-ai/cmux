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
