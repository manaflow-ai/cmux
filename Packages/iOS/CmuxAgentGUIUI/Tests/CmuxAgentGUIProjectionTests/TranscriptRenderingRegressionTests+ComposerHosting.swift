#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func sparseLiveRepresentablePreservesChronologyWithoutInteriorVoid() throws {
        let mounted = try Self.makeMountedSparseLiveRepresentable()
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        let rows = controller.currentRows
        let framesByID = try Dictionary(uniqueKeysWithValues: rows.map { row in
            let indexPath = try #require(controller.dataSource.indexPath(for: row.rowID))
            let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
            return (
                row.rowID,
                controller.collectionView.convert(attributes.frame, to: mounted.window).standardized
            )
        })
        let visualRows = rows.sorted {
            (framesByID[$0.rowID]?.minY ?? 0) < (framesByID[$1.rowID]?.minY ?? 0)
        }
        let viewport = controller.collectionView.convert(
            controller.collectionView.bounds,
            to: mounted.window
        ).standardized
        let pixelTolerance = 1 / max(mounted.window.screen.scale, 1)

        #expect(mounted.hosting.view.safeAreaInsets.top > 0)
        #expect(visualRows.count == 3)
        #expect(visualRows.first?.rowID == .entry(
            journalID: JournalID(rawValue: "sparse-live-representable"),
            seq: EntrySeq(rawValue: 1)
        ))
        #expect(visualRows.last?.rowID == .entry(
            journalID: JournalID(rawValue: "sparse-live-representable"),
            seq: EntrySeq(rawValue: 3)
        ))
        for pair in zip(visualRows, visualRows.dropFirst()) {
            let olderFrame = try #require(framesByID[pair.0.rowID])
            let newerFrame = try #require(framesByID[pair.1.rowID])
            #expect(abs(newerFrame.minY - olderFrame.maxY) <= pixelTolerance)
        }
        let newestFrame = try #require(visualRows.last.flatMap { framesByID[$0.rowID] })
        #expect(
            abs(
                viewport.maxY
                    - newestFrame.maxY
                    - controller.collectionView.adjustedContentInset.bottom
            ) <= pixelTolerance
        )
    }

    @Test func proseRowsUseSelectableNonScrollingTextViewsOnly() throws {
        let mounted = try Self.makeMountedSparseLiveRepresentable()
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        let cells = try controller.currentRows.map { row in
            let indexPath = try #require(controller.dataSource.indexPath(for: row.rowID))
            return (row, try #require(
                controller.collectionView.cellForItem(at: indexPath) as? TranscriptCollectionCell
            ))
        }

        for (row, cell) in cells {
            let textViews = Self.textViews(in: cell)
            switch row.rowKind {
            case .proseAgent, .proseUser:
                let textView = try #require(textViews.first)
                #expect(textViews.count == 1)
                #expect(textView.isSelectable)
                #expect(!textView.isEditable)
                #expect(!textView.isScrollEnabled)
            case .activitySummary:
                let textView = try #require(textViews.first)
                #expect(textViews.count == 1)
                #expect(textView.isSelectable)
                #expect(!textView.isEditable)
                #expect(!textView.isScrollEnabled)
            default:
                break
            }
        }
        #expect(controller.collectionView.panGestureRecognizer.isEnabled)
    }

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
        #expect(
            abs(
                viewport.maxY
                    - newestFrame.maxY
                    - controller.collectionView.adjustedContentInset.bottom
            ) <= pixelTolerance
        )
    }

    @available(iOS 26.0, *)
    @Test func liveComposerBandShapesNativeEdgeWithoutShrinkingTranscriptViewport() throws {
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
        transcript.setBottomEdgeElementContainers([composer])
        root.view.layoutIfNeeded()
        transcript.view.layoutIfNeeded()

        let transcriptViewport = transcript.transcript.collectionView.convert(
            transcript.transcript.collectionView.bounds,
            to: root.view
        ).standardized
        #expect(composer.frame.width > 0)
        #expect(composer.frame.height > 0)
        #expect(root.view.bounds.contains(composer.frame))
        #expect(transcriptViewport.maxY > composer.frame.minY)
        #expect(
            abs(transcriptViewport.maxY - root.view.bounds.maxY) < 0.5
        )
        #expect(
            transcript.transcript.collectionView.adjustedContentInset.bottom
                >= composerHeight + TranscriptListViewController.nativeBottomEdgeReadabilityClearance - 0.5
        )
        let interaction = try #require(composer.interactions.compactMap {
            $0 as? UIScrollEdgeElementContainerInteraction
        }.first)
        #expect(interaction.scrollView === transcript.transcript.collectionView)
        #expect(interaction.edge == .bottom)
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

    static func makeMountedSparseLiveRepresentable(
        density: TranscriptDensity = .comfortable
    ) throws -> (
        hosting: UIHostingController<AnyView>,
        window: UIWindow,
        container: TranscriptLiveContainerViewController,
        edgeContainer: UIView
    ) {
        let hosting = UIHostingController(rootView: AnyView(
            Self.sparseLiveRepresentable(
                entryCount: 1,
                density: density
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
        ))
        let navigation = UINavigationController(rootViewController: hosting)
        navigation.navigationBar.prefersLargeTitles = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        Self.pumpLiveRunLoop()
        let edgeContainer = UIView()
        edgeContainer.translatesAutoresizingMaskIntoConstraints = false
        edgeContainer.backgroundColor = .clear
        let edgeControl = UIButton(type: .system)
        edgeControl.translatesAutoresizingMaskIntoConstraints = false
        edgeControl.setImage(UIImage(systemName: "keyboard"), for: .normal)
        edgeContainer.addSubview(edgeControl)
        hosting.view.addSubview(edgeContainer)
        NSLayoutConstraint.activate([
            edgeContainer.leadingAnchor.constraint(equalTo: hosting.view.leadingAnchor),
            edgeContainer.trailingAnchor.constraint(equalTo: hosting.view.trailingAnchor),
            edgeContainer.bottomAnchor.constraint(equalTo: hosting.view.keyboardLayoutGuide.topAnchor),
            edgeContainer.heightAnchor.constraint(equalToConstant: 112),
            edgeControl.leadingAnchor.constraint(equalTo: edgeContainer.leadingAnchor, constant: 16),
            edgeControl.topAnchor.constraint(equalTo: edgeContainer.topAnchor, constant: 8),
            edgeControl.widthAnchor.constraint(equalToConstant: 44),
            edgeControl.heightAnchor.constraint(equalToConstant: 44),
        ])
        for count in 2...3 {
            hosting.rootView = AnyView(
                Self.sparseLiveRepresentable(
                    entryCount: count,
                    density: density,
                    bottomEdgeElementContainers: [edgeContainer]
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
            )
            Self.pumpLiveRunLoop()
        }
        let container = try #require(Self.liveContainer(in: hosting))
        container.transcript.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        return (hosting, window, container, edgeContainer)
    }

    private static func sparseLiveRepresentable(
        entryCount: Int,
        density: TranscriptDensity = .comfortable,
        bottomEdgeElementContainers: [UIView] = []
    ) -> TranscriptLiveControllerRepresentable {
        TranscriptLiveControllerRepresentable(
            input: TranscriptProjectionInput(entries: Array(Self.sparseLiveEntries.prefix(entryCount))),
            bottomChromeHeight: 112,
            bottomEdgeElementContainers: bottomEdgeElementContainers,
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0,
            density: density,
            answeringAskID: nil,
            failedAskID: nil,
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
    }

    private static var sparseLiveEntries: [EntrySnapshot] {
        let journal = JournalID(rawValue: "sparse-live-representable")
        return [
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
    }

    private static func liveContainer(
        in controller: UIViewController
    ) -> TranscriptLiveContainerViewController? {
        if let container = controller as? TranscriptLiveContainerViewController {
            return container
        }
        for child in controller.children {
            if let container = Self.liveContainer(in: child) {
                return container
            }
        }
        return nil
    }

    private static func textViews(in root: UIView) -> [UITextView] {
        let current = (root as? UITextView).map { [$0] } ?? []
        return current + root.subviews.flatMap { Self.textViews(in: $0) }
    }

    static func pumpLiveRunLoop(duration: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: duration))
    }

}
#endif
