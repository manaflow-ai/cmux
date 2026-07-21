#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func densitySwitchPreservesAnchorAtBottomMiddleAndTopInBothDirections() throws {
        for requestedPosition in [0.0, 0.05, 0.33, 0.5, 0.67, 1.0, -1.0] {
            let mounted = try Self.makeMountedDemo(tallFixture: true)
            defer { mounted.window.isHidden = true }
            let controller = mounted.container.transcript
            #expect(controller.view.safeAreaInsets.top > 0)
            let bottomOffsetY = controller.bottomRestOffset.y
            let historyOffsetY = -controller.collectionView.contentInset.top
            let range = bottomOffsetY - historyOffsetY
            let isJustInsideHistoryEnd = requestedPosition == -1
            let position = requestedPosition == 0.05 ? min(20 / max(range, 1), 1) : requestedPosition
            let isExactlyAtBottom = position == 0
            let isExactlyAtHistoryEnd = position == 1
            Self.scrollMountedController(
                controller,
                to: isJustInsideHistoryEnd
                    ? min(bottomOffsetY, historyOffsetY + 1)
                    : bottomOffsetY - (range * position)
            )
            controller.collectionView.layer.removeAllAnimations()
            controller.collectionView.visibleCells.forEach {
                $0.layer.removeAllAnimations()
                $0.contentView.layer.removeAllAnimations()
            }

            let comfortableAnchor = try #require(controller.captureAnchor())
            let comfortableScreenY = try Self.screenY(of: comfortableAnchor.rowID, in: controller)
            let comfortableSpacing = try Self.spacing(for: comfortableAnchor.rowID, in: controller)
            let comfortableVisualTopY = Self.visualContentTopY(
                rowTopY: comfortableScreenY,
                spacing: comfortableSpacing,
                in: controller
            )
            #expect(
                Self.nativePixelY(comfortableAnchor.screenY, in: controller)
                    == Self.nativePixelY(comfortableVisualTopY, in: controller)
            )
            let rowIDs = controller.dataSource.snapshot().itemIdentifiers
            let newestRowID = try #require(rowIDs.first)
            let comfortableNewestBottomY = try Self.contentScreenBottomY(of: newestRowID, in: controller)
            let pixelTolerance = 1 / (controller.view.window?.screen.scale ?? 1)

            Self.updateMountedDemo(mounted, density: .compact)

            let compactAnchorY = try Self.screenY(of: comfortableAnchor.rowID, in: controller)
            let compactTrace = try #require(controller.lastAnchorTrace)
            let compactSpacing = try Self.spacing(for: comfortableAnchor.rowID, in: controller)
            print("density-anchor comfortable->compact position=\(position) capturedScreenTop=\(compactTrace.capturedScreenTop) postLayoutAttributeTop=\(compactTrace.postLayoutAttributeTop) postLayoutVisualTop=\(compactTrace.postLayoutVisualTop) computedTargetOffset=\(compactTrace.computedTargetOffset) appliedOffset=\(compactTrace.appliedOffset) finalScreenTop=\(compactTrace.finalScreenTop)")
            #expect(controller.currentDensity == .compact)
            #expect(compactSpacing.density == .compact)
            #expect(
                controller.collectionView.contentOffset.y
                    <= Self.maximumContentOffsetY(in: controller) + pixelTolerance
            )
            if isExactlyAtBottom {
                let toggledRest = controller.collectionView.contentOffset
                #expect(toggledRest == controller.bottomRestOffset)
                controller.scrollToBottom(animated: false)
                Self.pumpMainRunLoop()
                #expect(controller.collectionView.contentOffset == toggledRest)
                #expect(Self.nativePixelY(try Self.contentScreenBottomY(of: newestRowID, in: controller), in: controller) == Self.nativePixelY(comfortableNewestBottomY, in: controller))
            } else if !isJustInsideHistoryEnd && !isExactlyAtHistoryEnd {
                #expect(
                    abs(Self.nativePixelY(Self.visualContentTopY(
                        rowTopY: compactAnchorY,
                        spacing: compactSpacing,
                        in: controller
                    ), in: controller) - Self.nativePixelY(comfortableVisualTopY, in: controller)) <= 1,
                    "The replay row's visual top must remain within one native pixel"
                )
            }

            let compactAnchor = try #require(controller.captureAnchor())
            let compactScreenY = try Self.screenY(of: compactAnchor.rowID, in: controller)
            let compactSelectedSpacing = try Self.spacing(for: compactAnchor.rowID, in: controller)
            let compactVisualTopY = Self.visualContentTopY(
                rowTopY: compactScreenY,
                spacing: compactSelectedSpacing,
                in: controller
            )
            Self.updateMountedDemo(mounted, density: .comfortable)

            let restoredAnchorY = try Self.screenY(of: compactAnchor.rowID, in: controller)
            let comfortableTrace = try #require(controller.lastAnchorTrace)
            print("density-anchor compact->comfortable position=\(position) capturedScreenTop=\(comfortableTrace.capturedScreenTop) postLayoutAttributeTop=\(comfortableTrace.postLayoutAttributeTop) postLayoutVisualTop=\(comfortableTrace.postLayoutVisualTop) computedTargetOffset=\(comfortableTrace.computedTargetOffset) appliedOffset=\(comfortableTrace.appliedOffset) finalScreenTop=\(comfortableTrace.finalScreenTop)")
            let restoredSpacing = try Self.spacing(for: compactAnchor.rowID, in: controller)
            #expect(controller.currentDensity == .comfortable)
            #expect(restoredSpacing.density == .comfortable)
            #expect(
                controller.collectionView.contentOffset.y
                    <= Self.maximumContentOffsetY(in: controller) + pixelTolerance
            )
            if isExactlyAtBottom {
                #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)
                #expect(Self.nativePixelY(try Self.contentScreenBottomY(of: newestRowID, in: controller), in: controller) == Self.nativePixelY(comfortableNewestBottomY, in: controller))
            } else if !isExactlyAtHistoryEnd {
                #expect(
                    abs(Self.nativePixelY(Self.visualContentTopY(
                        rowTopY: restoredAnchorY,
                        spacing: restoredSpacing,
                        in: controller
                    ), in: controller) - Self.nativePixelY(compactVisualTopY, in: controller)) <= 1,
                    "The replay row's reverse visual top must remain within one native pixel"
                )
            }
            #expect(controller.dataSource.snapshot().itemIdentifiers == rowIDs)
            #expect(controller.collectionView.layer.animationKeys()?.isEmpty != false)
            #expect(controller.collectionView.visibleCells.allSatisfy {
                ($0.layer.animationKeys() ?? []).isEmpty
                    && ($0.contentView.layer.animationKeys() ?? []).isEmpty
            })
        }
    }

    @Test func replayFirstLayoutUsesCanonicalRailAndSurvivesDensityRoundTrip() throws {
        let mounted = try Self.makeMountedDemo(tallFixture: false)
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        let seededFrames = try Self.rowFrames(in: controller)
        let firstFrame = try #require(seededFrames.values.first)

        for frame in seededFrames.values {
            #expect(abs(frame.minX - firstFrame.minX) < 0.5)
            #expect(abs(frame.maxX - firstFrame.maxX) < 0.5)
        }

        Self.updateMountedDemo(mounted, density: .compact)
        Self.updateMountedDemo(mounted, density: .comfortable)

        #expect(try Self.rowFrames(in: controller) == seededFrames)
    }

    @Test func densityChangeMidProjectionDoesNotChurnRowIDs() {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let input = TranscriptProjectionInput(entries: Self.densityEntries(count: 12))
        controller.apply(input: input)
        let comfortableIDs = controller.dataSource.snapshot().itemIdentifiers

        controller.setDensity(.compact)
        controller.apply(input: input)

        #expect(controller.dataSource.snapshot().itemIdentifiers == comfortableIDs)
    }

    @Test func compactActivityRowsShrinkAndRunningIndicatorSurvivesRoundTrip() throws {
        let rowID = TranscriptRowID.entry(
            journalID: JournalID(rawValue: "density-running"),
            seq: EntrySeq(rawValue: 2)
        )
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.apply(input: Self.runningActivityInput())
        Self.pumpMainRunLoop()

        let comfortableHeight = try Self.rowHeight(for: rowID, in: controller)
        try Self.expectRunningIndicator(for: rowID, in: controller)

        controller.setDensity(.compact)
        Self.pumpMainRunLoop()
        let compactHeight = try Self.rowHeight(for: rowID, in: controller)
        try Self.expectRunningIndicator(for: rowID, in: controller)

        controller.setDensity(.comfortable)
        Self.pumpMainRunLoop()
        let restoredHeight = try Self.rowHeight(for: rowID, in: controller)
        try Self.expectRunningIndicator(for: rowID, in: controller)

        #expect(compactHeight <= comfortableHeight - 5)
        #expect(abs(restoredHeight - comfortableHeight) < 0.5)
    }

    private static func expectRunningIndicator(
        for rowID: TranscriptRowID,
        in controller: TranscriptListViewController
    ) throws {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let cell = try #require(controller.collectionView.cellForItem(at: indexPath))
        let indicator = try #require(Self.activityIndicators(in: cell).first)
        #expect(indicator.isAnimating)
        #expect(!indicator.isHidden)
        #expect(indicator.alpha > 0.99)
        #expect(indicator.bounds.width > 0)
        #expect(indicator.bounds.height > 0)
    }

    private static func activityIndicators(in view: UIView) -> [UIActivityIndicatorView] {
        let current = (view as? UIActivityIndicatorView).map { [$0] } ?? []
        return current + view.subviews.flatMap { Self.activityIndicators(in: $0) }
    }

    private static func spacing(
        for rowID: TranscriptRowID,
        in controller: TranscriptListViewController
    ) throws -> TranscriptRowSpacing {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let cell = try #require(
            controller.collectionView.cellForItem(at: indexPath) as? TranscriptCollectionCell
        )
        return cell.rowSpacing
    }

    private static func screenY(of rowID: TranscriptRowID, in controller: TranscriptListViewController) throws -> CGFloat {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
        return controller.collectionView.convert(attributes.frame, to: controller.view.window).minY
    }

    private static func nativePixelY(_ value: CGFloat, in controller: TranscriptListViewController) -> Int {
        let scale = controller.view.window?.screen.scale ?? 1
        return Int((value * scale).rounded())
    }

    private static func visualContentTopY(
        rowTopY: CGFloat,
        spacing: TranscriptRowSpacing,
        in controller: TranscriptListViewController
    ) -> CGFloat {
        let scale = controller.view.window?.screen.scale ?? 1
        return ((rowTopY + spacing.top) * scale).rounded() / scale
    }

    private static func contentScreenBottomY(of rowID: TranscriptRowID, in controller: TranscriptListViewController) throws -> CGFloat {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
        let spacing = try #require(controller.spacingByID[rowID])
        return controller.collectionView.convert(attributes.frame, to: controller.view.window).maxY - spacing.bottom
    }

    private static func rowHeight(
        for rowID: TranscriptRowID,
        in controller: TranscriptListViewController
    ) throws -> CGFloat {
        let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
        return try #require(controller.collectionView.layoutAttributesForItem(at: indexPath)).frame.height
    }

    private static func makeMountedDemo(
        tallFixture: Bool
    ) throws -> (
        hosting: UIHostingController<TranscriptDemoControllerRepresentable>,
        window: UIWindow,
        container: TranscriptDemoContainerViewController,
        model: TranscriptDemoModel
    ) {
        let model = TranscriptDemoModel()
        let hosting = UIHostingController(rootView: Self.demoRepresentable(
            input: model.input,
            density: .comfortable
        ))
        hosting.navigationItem.title = AgentGUIL10n.string(
            "agent.demo.title",
            defaultValue: "Transcript Demo"
        )
        let navigation = UINavigationController(rootViewController: hosting)
        navigation.navigationBar.prefersLargeTitles = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        Self.pumpMainRunLoop()

        for _ in 0..<32 {
            model.step()
            hosting.rootView = Self.demoRepresentable(input: model.input, density: .comfortable)
            Self.pumpMainRunLoop()
        }
        if tallFixture {
            model.setTallFixtureEnabled(true)
            hosting.rootView = Self.demoRepresentable(input: model.input, density: .comfortable)
            Self.pumpMainRunLoop()
        }
        let container = try #require(Self.demoContainer(in: hosting))
        container.additionalSafeAreaInsets.top = window.safeAreaInsets.top
        Self.pumpMainRunLoop()
        return (hosting, window, container, model)
    }

    private static func updateMountedDemo(
        _ mounted: (
            hosting: UIHostingController<TranscriptDemoControllerRepresentable>,
            window: UIWindow,
            container: TranscriptDemoContainerViewController,
            model: TranscriptDemoModel
        ),
        density: TranscriptDensity
    ) {
        mounted.hosting.rootView = Self.demoRepresentable(
            input: mounted.model.input,
            density: density
        )
        Self.pumpMainRunLoop()
    }

    private static func demoRepresentable(
        input: TranscriptProjectionInput,
        density: TranscriptDensity
    ) -> TranscriptDemoControllerRepresentable {
        TranscriptDemoControllerRepresentable(
            input: input,
            theme: AgentGUITheme(terminalTheme: .monokai),
            jumpToken: 0,
            // 44pt field + 8pt stack gap + 56pt controls + 16pt outer padding.
            // The transcript adds its own 8pt breathing gap at the viewport boundary.
            bottomChromeHeight: 124,
            density: density
        )
    }

    private static func pumpMainRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private static func scrollMountedController(
        _ controller: TranscriptListViewController,
        to targetOffsetY: CGFloat
    ) {
        let step = max(controller.collectionView.bounds.height * 0.75, 1)
        var offsetY = controller.collectionView.contentOffset.y
        while abs(offsetY - targetOffsetY) > 0.5 {
            let delta = min(abs(targetOffsetY - offsetY), step)
            offsetY += targetOffsetY > offsetY ? delta : -delta
            controller.collectionView.setContentOffset(
                CGPoint(x: controller.bottomRestOffset.x, y: offsetY),
                animated: false
            )
            Self.pumpMainRunLoop()
        }
    }

    private static func demoContainer(
        in controller: UIViewController
    ) -> TranscriptDemoContainerViewController? {
        if let container = controller as? TranscriptDemoContainerViewController {
            return container
        }
        for child in controller.children {
            if let container = Self.demoContainer(in: child) {
                return container
            }
        }
        return nil
    }

    private static func maximumContentOffsetY(in controller: TranscriptListViewController) -> CGFloat {
        max(
            controller.bottomRestOffset.y,
            controller.collectionView.contentSize.height
                - controller.collectionView.bounds.height
                + controller.collectionView.contentInset.bottom
        )
    }

    private static func rowFrames(
        in controller: TranscriptListViewController
    ) throws -> [TranscriptRowID: CGRect] {
        let pairs = try controller.dataSource.snapshot().itemIdentifiers.map { rowID in
            let indexPath = try #require(controller.dataSource.indexPath(for: rowID))
            let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
            return (rowID, attributes.frame)
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    private static func runningActivityInput() -> TranscriptProjectionInput {
        let journal = JournalID(rawValue: "density-running")
        let user: EntryPayload = .userMessage(UserMessagePayload(
            text: "Run the checks",
            attachmentCount: 0,
            hasImage: false
        ))
        let tool: EntryPayload = .toolRun(ToolRunPayload(
            toolName: "swift test",
            argumentSummary: "Rendering regressions",
            isTerminal: true,
            isRunning: true
        ))
        return TranscriptProjectionInput(
            entries: [
                EntrySnapshot(
                    journalID: journal,
                    seq: EntrySeq(rawValue: 1),
                    kind: user.kind,
                    content: EntryContent(contentHash: 1, payload: user),
                    version: EntityVersion(rawValue: 1)
                ),
                EntrySnapshot(
                    journalID: journal,
                    seq: EntrySeq(rawValue: 2),
                    kind: tool.kind,
                    content: EntryContent(contentHash: 2, payload: tool),
                    version: EntityVersion(rawValue: 2)
                ),
            ],
            sessionPhase: .working
        )
    }

    private static func densityEntries(count: Int) -> [EntrySnapshot] {
        let journal = JournalID(rawValue: "density-test")
        return (1...count).map { seq in
            let payload: EntryPayload = seq.isMultiple(of: 2)
                ? .agentProse(AgentProsePayload(markdown: "Answer \(seq) with readable prose."))
                : .userMessage(UserMessagePayload(
                    text: "Prompt \(seq)",
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
    }
}
#endif
