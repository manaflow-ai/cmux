#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func sparseThreeRowConversationStacksContiguouslyAtNewestEdge() throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let journal = JournalID(rawValue: "sparse-live")
        controller.setBottomChromeHeight(112)
        let entries = [
            EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: 1),
                kind: .userMessage,
                content: EntryContent(
                    contentHash: 1,
                    payload: .userMessage(UserMessagePayload(
                        text: "Hello",
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
                        toolName: "Read",
                        argumentSummary: "one file",
                        isTerminal: false,
                        isRunning: false
                    ))
                ),
                version: EntityVersion(rawValue: 2)
            ),
            EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: 3),
                kind: .agentProse,
                content: EntryContent(
                    contentHash: 3,
                    payload: .agentProse(AgentProsePayload(markdown: "Hello there, happy to help!"))
                ),
                version: EntityVersion(rawValue: 3)
            ),
        ]
        for count in 1...entries.count {
            controller.apply(input: TranscriptProjectionInput(entries: Array(entries.prefix(count))))
            controller.view.layoutIfNeeded()
            controller.collectionView.layoutIfNeeded()
        }
        controller.scrollToBottom(animated: false)
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()

        let frames = try controller.currentRows.map { row in
            let indexPath = try #require(controller.dataSource.indexPath(for: row.rowID))
            let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
            return controller.collectionView.convert(attributes.frame, to: controller.view).standardized
        }.sorted { $0.minY < $1.minY }
        let viewport = controller.collectionView.convert(controller.collectionView.bounds, to: controller.view).standardized
        let pixelTolerance = 1 / max(window.screen.scale, 1)
        let oldestFrame = try #require(frames.first)
        let newestFrame = try #require(frames.last)

        #expect(frames.count == 3)
        #expect(controller.collectionView.contentSize.height >= controller.collectionView.bounds.height)
        #expect(frames.allSatisfy { $0.height < 180 })
        #expect(newestFrame.maxY - oldestFrame.minY < 320)
        for pair in zip(frames, frames.dropFirst()) {
            #expect(abs(pair.1.minY - pair.0.maxY) <= pixelTolerance)
        }
        #expect(abs(newestFrame.maxY - viewport.maxY) <= pixelTolerance)
    }

    @Test func liveComposerBandRemainsVisuallyExposedAboveTranscriptViewport() throws {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let composerHeight: CGFloat = 112
        let composer = UIView(frame: CGRect(
            x: 0,
            y: root.view.bounds.height - composerHeight,
            width: root.view.bounds.width,
            height: composerHeight
        ))
        composer.backgroundColor = .systemPink
        root.view.addSubview(composer)

        let transcript = TranscriptLiveContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0
        )
        root.addChild(transcript)
        transcript.view.frame = root.view.bounds
        root.view.addSubview(transcript.view)
        transcript.didMove(toParent: root)
        transcript.setBottomChromeHeight(composerHeight)
        root.view.layoutIfNeeded()
        transcript.view.layoutIfNeeded()

        let transcriptViewport = transcript.transcript.collectionView.convert(
            transcript.transcript.collectionView.bounds,
            to: root.view
        ).standardized
        #expect(composer.frame.width > 0)
        #expect(composer.frame.height > 0)
        #expect(root.view.bounds.contains(composer.frame))
        #expect(transcriptViewport.maxY <= composer.frame.minY)
        #expect(transcript.view.backgroundColor == UIColor.clear)
        #expect(transcript.transcript.view.backgroundColor == UIColor.clear)
    }

    @Test func demoComposerBandTranslatesWithoutChangingGlassSubtreeGeometry() throws {
        let container = TranscriptDemoContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai)
        )
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        container.installComposer(
            model: TranscriptDemoModel(),
            density: .constant(.comfortable)
        )
        container.view.layoutIfNeeded()

        let hostView = try #require(container.composerHostView)
        let hostIdentity = ObjectIdentifier(hostView)
        let initialBounds = hostView.bounds
        let initialFrame = hostView.frame
        let initialChromeHeight = container.transcript.bottomChromeHeight
        let bottomConstraint = try #require(container.composerBottomConstraint)

        bottomConstraint.constant = -320
        UIView.performWithoutAnimation {
            container.view.layoutIfNeeded()
        }

        #expect(ObjectIdentifier(try #require(container.composerHostView)) == hostIdentity)
        #expect(hostView.bounds == initialBounds)
        #expect(hostView.frame.minY == initialFrame.minY - 320)
        #expect(container.transcript.bottomChromeHeight == initialChromeHeight)
    }
}
#endif
