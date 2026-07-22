#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing
import UIKit

@Suite(.serialized) @MainActor struct TranscriptRenderingRegressionTests {
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
        let window = UIWindow(frame: container.view.frame)
        window.rootViewController = container
        window.isHidden = false
        defer { window.isHidden = true }
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
        let list = container.transcript
        let collection = list.collectionView!
        let historyOffsetY = -collection.contentInset.top
        let middleOffsetY = (historyOffsetY + list.bottomRestOffset.y) / 2
        collection.setContentOffset(CGPoint(x: 0, y: middleOffsetY), animated: false)
        let offset = collection.contentOffset

        container.apply(theme: replacement, terminalThemeGeneration: 5)

        #expect(container.transcript === list)
        #expect(container.transcript.collectionView === collection)
        #expect(collection.contentOffset == offset)
        #expect(container.terminalThemeGeneration == 5)
        #expect(list.currentTheme == replacement)
        #expect(container.view.backgroundColor == UIColor.clear)
        #expect(collection.backgroundColor == UIColor(replacement.background))
    }

    @Test func terminalThemeBackgroundOwnsContainerListAndCellCanvas() throws {
        var terminalTheme = TerminalTheme.monokai
        terminalTheme.background = "#102030"
        terminalTheme.foreground = "#f4f0d8"
        let theme = AgentGUITheme(terminalTheme: terminalTheme)
        let controller = TranscriptLiveContainerViewController(
            theme: theme,
            terminalThemeGeneration: 1
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.apply(input: TranscriptProjectionInput(entries: [
            EntrySnapshot(
                journalID: JournalID(rawValue: "background-owner"),
                seq: EntrySeq(rawValue: 1),
                kind: EntryKind.agentProse,
                content: EntryContent(
                    contentHash: 1,
                    payload: .agentProse(AgentProsePayload(markdown: "Visible answer"))
                ),
                version: EntityVersion(rawValue: 1)
            ),
        ]))
        controller.view.layoutIfNeeded()
        controller.transcript.collectionView.layoutIfNeeded()

        let cell = try #require(
            controller.transcript.collectionView.visibleCells.first as? TranscriptCollectionCell
        )
        #expect(controller.view.backgroundColor == UIColor.clear)
        #expect(controller.transcript.view.backgroundColor == UIColor.clear)
        #expect(controller.transcript.collectionView.backgroundColor == UIColor(theme.background))
        #expect(cell.backgroundConfiguration?.backgroundColor == UIColor.clear)
        #expect(cell.contentView.backgroundColor == UIColor.clear)
    }

    @Test func reusedSummaryCellKeepsStableHeightAcrossTurns() {
        let theme = AgentGUITheme(terminalTheme: .monokai)
        let cell = TranscriptCollectionCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let firstRow = Self.summaryRow(journal: "summary-a", promptSeq: 1)
        let secondRow = Self.summaryRow(journal: "summary-b", promptSeq: 2)

        cell.configure(
            row: firstRow,
            spacing: TranscriptRowSpacing(top: 0, bottom: 0),
            theme: theme,
            answeringAskID: nil,
            failedAskID: nil,
            onShowActivity: { _ in },
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
        let firstHeight = Self.fittingHeight(of: cell)

        cell.configure(
            row: secondRow,
            spacing: TranscriptRowSpacing(top: 0, bottom: 0),
            theme: theme,
            answeringAskID: nil,
            failedAskID: nil,
            onShowActivity: { _ in },
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
        let secondHeight = Self.fittingHeight(of: cell)

        #expect(cell.row?.turnID == secondRow.turnID)
        #expect(abs(firstHeight - secondHeight) < 0.5)
    }

    @Test func activityPresentationDoesNotMutateSnapshotOrLayout() throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let journal = JournalID(rawValue: "animation-free-toggle")
        controller.apply(input: TranscriptProjectionInput(entries: [
            EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: 1),
                kind: .userMessage,
                content: EntryContent(
                    contentHash: 1,
                    payload: .userMessage(UserMessagePayload(
                        text: "Prompt",
                        attachmentCount: 0,
                        hasImage: false
                    ))
                ),
                version: EntityVersion(rawValue: 1)
            ),
            EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: 2),
                kind: .toolRun,
                content: EntryContent(
                    contentHash: 2,
                    payload: .toolRun(ToolRunPayload(
                        toolName: "rg",
                        argumentSummary: "Sources",
                        isTerminal: false,
                        isRunning: false
                    ))
                ),
                version: EntityVersion(rawValue: 2)
            ),
        ]))
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
        let summaryRow = try #require(controller.rowsByID.values.first {
            if case .activitySummary = $0.rowKind { return true }
            return false
        })
        let summaryCell = try #require(controller.collectionView.visibleCells.first {
            ($0 as? TranscriptCollectionCell)?.row?.rowID == summaryRow.rowID
        } as? TranscriptCollectionCell)
        guard case .activitySummary(let summary) = summaryRow.rowKind,
              let turnID = summaryRow.turnID
        else {
            Issue.record("Expected an activity summary with a turn identity")
            return
        }
        let snapshotIDs = controller.dataSource.snapshot().itemIdentifiers
        let initialFrame = summaryCell.frame
        var presentedDetails: TranscriptActivityDetails?
        controller.applyActivityPresentation { presentedDetails = $0 }

        controller.onShowActivity(TranscriptActivityDetails(turnID: turnID, summary: summary))
        controller.collectionView.layoutIfNeeded()

        #expect(presentedDetails?.turnID == turnID)
        #expect(controller.dataSource.snapshot().itemIdentifiers == snapshotIDs)
        #expect(summaryCell.frame == initialFrame)
        #expect(controller.collectionView.layer.animationKeys()?.isEmpty != false)
        #expect(summaryCell.layer.animationKeys()?.isEmpty != false)
        #expect(summaryCell.contentView.layer.animationKeys()?.isEmpty != false)
        #expect(controller.collectionView.visibleCells.allSatisfy {
            ($0.layer.animationKeys() ?? []).isEmpty
                && ($0.contentView.layer.animationKeys() ?? []).isEmpty
        })
    }

    @Test func failedAskRemeasuresWithoutClippingAndRetryRestoresHeight() throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        Self.pumpRenderingRunLoop()

        let journal = JournalID(rawValue: "failed-ask-layout")
        let entries = (1...40).map { seq in
            let payload: EntryPayload = seq.isMultiple(of: 2)
                ? .agentProse(AgentProsePayload(
                    markdown: "History answer \(seq) keeps the ask near the newest edge."
                ))
                : .userMessage(UserMessagePayload(
                    text: "History prompt \(seq)",
                    attachmentCount: 0,
                    hasImage: false
                ))
            return EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: seq),
                kind: payload.kind,
                content: EntryContent(contentHash: seq, payload: payload),
                version: EntityVersion(rawValue: UInt64(seq))
            )
        }
        let ask = PendingAsk(
            id: "failed-ask",
            sessionID: AgentSessionID(rawValue: "failed-ask-session"),
            kind: .question,
            promptSummary: "Choose a recovery path",
            options: ["Retry", "Cancel"],
            state: .active
        )
        controller.apply(input: TranscriptProjectionInput(entries: entries, asks: [ask]))
        Self.pumpRenderingRunLoop()

        let rowID = TranscriptRowID.pendingAsk(ask.id)
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let initialAttributes = try #require(
            controller.collectionView.layoutAttributesForItem(at: indexPath)
        )
        let initialHeight = initialAttributes.frame.height
        let initialScreenY = controller.collectionView.convert(
            initialAttributes.frame,
            to: controller.view
        ).standardized.minY
        let pixelTolerance = 1 / (controller.view.window?.screen.scale ?? 1)

        controller.applyPendingAskInteraction(
            answeringAskID: nil,
            failedAskID: ask.id,
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
        Self.pumpRenderingRunLoop()

        let failedAttributes = try #require(
            controller.collectionView.layoutAttributesForItem(at: indexPath)
        )
        let failedHeight = failedAttributes.frame.height
        let failedFittingHeight = controller.heightForRow(
            at: indexPath,
            width: controller.collectionView.bounds.width
        )
        let failedScreenY = controller.collectionView.convert(
            failedAttributes.frame,
            to: controller.view
        ).standardized.minY
        let failedCell = try #require(
            controller.collectionView.cellForItem(at: indexPath) as? TranscriptCollectionCell
        )
        #expect(failedHeight > initialHeight)
        #expect(abs(failedHeight - failedFittingHeight) <= pixelTolerance)
        #expect(failedCell.contentView.bounds.height + pixelTolerance >= failedFittingHeight)
        #expect(abs(failedScreenY - initialScreenY) <= pixelTolerance)

        controller.applyPendingAskInteraction(
            answeringAskID: nil,
            failedAskID: nil,
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
        Self.pumpRenderingRunLoop()

        let restoredAttributes = try #require(
            controller.collectionView.layoutAttributesForItem(at: indexPath)
        )
        let restoredScreenY = controller.collectionView.convert(
            restoredAttributes.frame,
            to: controller.view
        ).standardized.minY
        #expect(abs(restoredAttributes.frame.height - initialHeight) <= pixelTolerance)
        #expect(abs(restoredScreenY - initialScreenY) <= pixelTolerance)
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
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
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
        let layoutComputationCount = controller.layoutComputationCount

        controller.apply(theme: replacement)

        #expect(controller.collectionView === collection)
        #expect(cell == nil || controller.collectionView.visibleCells.contains { $0 === cell })
        #expect(controller.collectionView.contentOffset == offset)
        #expect(controller.layoutComputationCount == layoutComputationCount)
        #expect(controller.currentTheme == replacement)
        #expect(controller.pillHost?.rootView.theme == replacement)
    }

    private static func summaryRow(journal: String, promptSeq: Int) -> TranscriptRow {
        let journalID = JournalID(rawValue: journal)
        let turnID = TranscriptTurnID(
            journalID: journalID,
            promptSeq: EntrySeq(rawValue: promptSeq),
            segmentAnchorSeq: EntrySeq(rawValue: promptSeq)
        )
        let items = (1...2).map { seq in
            TranscriptActivityItem(
                id: .entry(journalID: journalID, seq: EntrySeq(rawValue: seq + promptSeq)),
                kind: .tool,
                summary: "Activity \(seq)",
                isRunning: false
            )
        }
        return TranscriptRow(
            rowID: .activitySummary(turnID),
            rowKind: .activitySummary(TranscriptActivitySummary(
                editedFileCount: 0,
                readFileCount: 0,
                searchedCode: false,
                listedFiles: false,
                commandCount: items.count,
                eventCount: 0,
                items: items
            )),
            turnID: turnID,
            endsTurn: true
        )
    }

    private static func fittingHeight(of cell: TranscriptCollectionCell) -> CGFloat {
        cell.rowLayoutResult?.height ?? 0
    }

    private static func pumpRenderingRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

}
#endif
