#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func keyboardPinsBottomButLeavesMidHistoryStationaryInLiveContainer() throws {
        let bottomMount = Self.makeSlice2PhysicsMount()
        defer { bottomMount.window.isHidden = true }
        let bottomController = bottomMount.container.transcript
        bottomController.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        let newestID = try #require(bottomController.currentRows.first?.rowID)
        let bottomBefore = try Self.slice2ScreenFrame(of: newestID, in: bottomController).maxY
        let composerBefore = bottomMount.composer.convert(bottomMount.composer.bounds, to: bottomMount.window).minY

        #expect(bottomMount.field.becomeFirstResponder())
        Self.pumpLiveRunLoop(duration: 0.7)
        let bottomAfter = try Self.slice2ScreenFrame(of: newestID, in: bottomController).maxY
        let composerAfter = bottomMount.composer.convert(bottomMount.composer.bounds, to: bottomMount.window).minY
        let pixelTolerance = 1 / max(bottomMount.window.screen.scale, 1)
        #expect(abs((bottomAfter - bottomBefore) - (composerAfter - composerBefore)) <= pixelTolerance)
        #expect(bottomController.collectionView.contentOffset == bottomController.bottomRestOffset)
        bottomMount.field.resignFirstResponder()
        Self.pumpLiveRunLoop(duration: 0.4)

        let historyMount = Self.makeSlice2PhysicsMount()
        defer { historyMount.window.isHidden = true }
        let historyController = historyMount.container.transcript
        let historyY = (-historyController.collectionView.contentInset.top + historyController.bottomRestOffset.y) / 2
        historyController.collectionView.setContentOffset(CGPoint(x: 0, y: historyY), animated: false)
        historyController.collectionView.layoutIfNeeded()
        let anchor = try #require(historyController.captureAnchor())
        let historyBefore = try Self.slice2ScreenFrame(of: anchor.rowID, in: historyController).minY

        #expect(historyMount.field.becomeFirstResponder())
        Self.pumpLiveRunLoop(duration: 0.7)
        let historyAfter = try Self.slice2ScreenFrame(of: anchor.rowID, in: historyController).minY
        #expect(abs(historyAfter - historyBefore) <= 1 / max(historyMount.window.screen.scale, 1))
        historyMount.field.resignFirstResponder()
        Self.pumpLiveRunLoop(duration: 0.4)
    }

    @Test func liveTranscriptOwnsScrollToTopExclusivelyAndRestoresSiblingsOnExit() {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = root
        let terminal = UIScrollView(frame: root.view.bounds)
        let accessory = UIScrollView(frame: CGRect(x: 0, y: 700, width: 393, height: 44))
        terminal.scrollsToTop = true
        accessory.scrollsToTop = true
        root.view.addSubview(terminal)
        root.view.addSubview(accessory)
        let container = TranscriptLiveContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0
        )
        root.addChild(container)
        container.view.frame = root.view.bounds
        root.view.addSubview(container.view)
        container.didMove(toParent: root)
        window.makeKeyAndVisible()
        container.viewWillAppear(false)

        #expect(container.transcript.collectionView.scrollsToTop)
        #expect(!terminal.scrollsToTop)
        #expect(!accessory.scrollsToTop)

        container.viewDidDisappear(false)
        #expect(terminal.scrollsToTop)
        #expect(accessory.scrollsToTop)
        window.isHidden = true
    }

    @Test func scrollToBottomPillUsesFortyPointDistanceThresholdWithoutUnreadRows() {
        let mounted = Self.makeSlice2PhysicsMount()
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        controller.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        #expect(controller.unreadCount == 0)
        #expect(controller.pillHost?.view.alpha == 0)

        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: controller.bottomRestOffset.y - 39),
            animated: false
        )
        controller.scrollViewDidScroll(controller.collectionView)
        #expect(controller.pillHost?.view.alpha == 0)

        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: controller.bottomRestOffset.y - 41),
            animated: false
        )
        controller.scrollViewDidScroll(controller.collectionView)
        #expect(controller.pillHost?.view.alpha == 1)

        controller.scrollToBottom(animated: false)
        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)
        #expect(controller.pillHost?.view.alpha == 0)
    }

    @Test func scrollToBottomPillUsesMatchedNearAndFarChoreographyAndLandsExactly() throws {
        let mounted = Self.makeSlice2PhysicsMount()
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        let nearDistance = controller.collectionView.bounds.height
        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: controller.bottomRestOffset.y - nearDistance),
            animated: false
        )
        controller.scrollViewDidScroll(controller.collectionView)

        try #require(controller.pillHost).rootView.action()
        #expect(abs((controller.scrollAnimator?.duration ?? 0) - 0.45) < 0.001)
        Self.pumpLiveRunLoop(duration: 0.55)
        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)

        let historyTop = -controller.collectionView.contentInset.top
        controller.collectionView.setContentOffset(CGPoint(x: 0, y: historyTop), animated: false)
        controller.scrollViewDidScroll(controller.collectionView)
        #expect(controller.distanceFromBottom >= controller.collectionView.bounds.height * 1.75)

        try #require(controller.pillHost).rootView.action()
        Self.pumpLiveRunLoop(duration: 0.5)
        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)
    }

    private static func makeSlice2PhysicsMount() -> (
        window: UIWindow,
        root: UIViewController,
        container: TranscriptLiveContainerViewController,
        composer: UIView,
        field: UITextField
    ) {
        let root = UIViewController()
        root.additionalSafeAreaInsets = UIEdgeInsets(top: 18, left: 0, bottom: 14, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = root
        let container = TranscriptLiveContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0
        )
        root.addChild(container)
        container.view.frame = root.view.bounds
        root.view.addSubview(container.view)
        container.didMove(toParent: root)
        let composer = UIView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(composer)
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        composer.addSubview(field)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: root.view.keyboardLayoutGuide.topAnchor),
            composer.heightAnchor.constraint(equalToConstant: 112),
        ])
        window.makeKeyAndVisible()
        container.setBottomChromeHeight(112)
        container.setBottomEdgeElementContainers([composer])
        container.apply(input: TranscriptProjectionInput(entries: Self.slice2PhysicsEntries))
        Self.pumpLiveRunLoop()
        container.transcript.collectionView.layoutIfNeeded()
        return (window, root, container, composer, field)
    }

    private static var slice2PhysicsEntries: [EntrySnapshot] {
        let journal = JournalID(rawValue: "slice-2-physics")
        return (1...80).map { sequence in
            let payload: EntryPayload = sequence.isMultiple(of: 2)
                ? .agentProse(AgentProsePayload(markdown: "Answer \(sequence) with enough text to wrap onto another line."))
                : .userMessage(UserMessagePayload(
                    text: "Prompt \(sequence)",
                    attachmentCount: 0,
                    hasImage: false
                ))
            return EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: sequence),
                kind: payload.kind,
                content: EntryContent(contentHash: sequence, payload: payload),
                version: EntityVersion(rawValue: UInt64(sequence))
            )
        }
    }

    private static func slice2ScreenFrame(
        of rowID: TranscriptRowID,
        in controller: TranscriptListViewController
    ) throws -> CGRect {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
        return controller.collectionView.convert(attributes.frame, to: controller.view.window).standardized
    }
}
#endif
