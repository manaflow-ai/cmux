#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @available(iOS 26.0, *)
    @Test(arguments: [TranscriptDensity.comfortable, TranscriptDensity.compact])
    func nativeBottomEdgeKeepsNewestInkReadableAtLiveBottomRest(
        density: TranscriptDensity
    ) throws {
        let mounted = try Self.makeMountedSparseLiveRepresentable(density: density)
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        controller.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        try Self.expectNativeBottomEdgeGeometry(
            controller: controller,
            edgeContainer: mounted.edgeContainer,
            window: mounted.window
        )

        let keyboardField = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mounted.hosting.view.addSubview(keyboardField)
        let keyboardDownHeight = controller.collectionView.bounds.height
        let keyboardDownBottom = controller.collectionView.convert(
            controller.collectionView.bounds,
            to: mounted.window
        ).maxY
        #expect(keyboardField.becomeFirstResponder())
        Self.pumpLiveRunLoop(duration: 0.7)
        let keyboardUpBottom = controller.collectionView.convert(
            controller.collectionView.bounds,
            to: mounted.window
        ).maxY

        #expect(keyboardUpBottom < keyboardDownBottom - 100)
        #expect(abs(controller.collectionView.bounds.height - keyboardDownHeight) < 0.5)
        try Self.expectNativeBottomEdgeGeometry(
            controller: controller,
            edgeContainer: mounted.edgeContainer,
            window: mounted.window
        )
        keyboardField.resignFirstResponder()
        Self.pumpLiveRunLoop(duration: 0.4)
    }

    @available(iOS 26.0, *)
    @Test(arguments: [TranscriptDensity.comfortable, TranscriptDensity.compact])
    func nativeBottomEdgeKeepsNewestInkReadableInHostedDemo(
        density: TranscriptDensity
    ) throws {
        let mounted = try Self.makeMountedNativeEdgeDemo(density: density)
        defer { mounted.window.isHidden = true }
        let controller = mounted.container.transcript
        let composer = try #require(mounted.container.composerHostView)
        controller.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        try Self.expectNativeBottomEdgeGeometry(
            controller: controller,
            edgeContainer: composer,
            window: mounted.window
        )

        let keyboardField = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mounted.hosting.view.addSubview(keyboardField)
        let keyboardDownHeight = controller.collectionView.bounds.height
        let keyboardDownBottom = controller.collectionView.convert(
            controller.collectionView.bounds,
            to: mounted.window
        ).maxY
        #expect(keyboardField.becomeFirstResponder())
        Self.pumpLiveRunLoop(duration: 0.7)
        let keyboardUpBottom = controller.collectionView.convert(
            controller.collectionView.bounds,
            to: mounted.window
        ).maxY

        #expect(keyboardUpBottom < keyboardDownBottom - 100)
        #expect(abs(controller.collectionView.bounds.height - keyboardDownHeight) < 0.5)
        try Self.expectNativeBottomEdgeGeometry(
            controller: controller,
            edgeContainer: composer,
            window: mounted.window
        )
        keyboardField.resignFirstResponder()
        Self.pumpLiveRunLoop(duration: 0.4)
    }

    @available(iOS 26.0, *)
    private static func makeMountedNativeEdgeDemo(
        density: TranscriptDensity
    ) throws -> (
        hosting: UIHostingController<AnyView>,
        window: UIWindow,
        container: TranscriptDemoContainerViewController
    ) {
        let model = TranscriptDemoModel()
        model.appendBurstRows()
        let hosting = UIHostingController(rootView: AnyView(
            TranscriptDemoControllerRepresentable(
                input: model.input,
                theme: AgentGUITheme(terminalTheme: .monokai),
                jumpToken: 0,
                bottomChromeHeight: 0,
                density: density,
                composerModel: model,
                densityBinding: .constant(density)
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
        ))
        let navigation = UINavigationController(rootViewController: hosting)
        navigation.navigationBar.prefersLargeTitles = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        Self.pumpLiveRunLoop()
        let container = try #require(Self.nativeEdgeDemoContainer(in: hosting))
        container.transcript.scrollToBottom(animated: false)
        Self.pumpLiveRunLoop()
        return (hosting, window, container)
    }

    private static func nativeEdgeDemoContainer(
        in controller: UIViewController
    ) -> TranscriptDemoContainerViewController? {
        if let container = controller as? TranscriptDemoContainerViewController {
            return container
        }
        for child in controller.children {
            if let container = Self.nativeEdgeDemoContainer(in: child) {
                return container
            }
        }
        return nil
    }

    @available(iOS 26.0, *)
    private static func expectNativeBottomEdgeGeometry(
        controller: TranscriptListViewController,
        edgeContainer: UIView,
        window: UIWindow
    ) throws {
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
        let interaction = try #require(edgeContainer.interactions.compactMap {
            $0 as? UIScrollEdgeElementContainerInteraction
        }.first)
        #expect(interaction.scrollView === controller.collectionView)
        #expect(interaction.edge == .bottom)
        #expect(!controller.collectionView.topEdgeEffect.isHidden)
        #expect(!controller.collectionView.bottomEdgeEffect.isHidden)

        let newestRow = try #require(controller.currentRows.first)
        let newestIndexPath = try #require(controller.dataSource.indexPath(for: newestRow.rowID))
        let newestAttributes = try #require(
            controller.collectionView.layoutAttributesForItem(at: newestIndexPath)
        )
        let spacing = try #require(controller.spacingByID[newestRow.rowID])
        let newestFrame = controller.collectionView.convert(newestAttributes.frame, to: window).standardized
        let newestInkBottom = newestFrame.maxY - spacing.bottom
        let effectFrames = Self.nativeEdgeViews(
            named: "ScrollEdgeEffectView",
            in: controller.collectionView
        ).map { $0.convert($0.bounds, to: window).standardized }
        let edgeFrame = edgeContainer.convert(edgeContainer.bounds, to: window).standardized
        let viewport = controller.collectionView.convert(controller.collectionView.bounds, to: window).standardized
        let bottomEffect = try #require(effectFrames.first { abs($0.maxY - viewport.maxY) < 1 })
        let pixelTolerance = 1 / max(window.screen.scale, 1)

        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)
        #expect(
            controller.collectionView.adjustedContentInset.bottom
                >= controller.bottomChromeHeight + TranscriptListViewController.nativeBottomEdgeReadabilityClearance - 0.5
        )
        #expect(bottomEffect.minY < edgeFrame.minY)
        #expect(edgeFrame.minY < bottomEffect.maxY)
        #expect(newestInkBottom <= bottomEffect.minY + pixelTolerance)
    }

    private static func nativeEdgeViews(named typeName: String, in root: UIView) -> [UIView] {
        let current = String(describing: type(of: root)) == typeName ? [root] : []
        return current + root.subviews.flatMap { Self.nativeEdgeViews(named: typeName, in: $0) }
    }
}
#endif
