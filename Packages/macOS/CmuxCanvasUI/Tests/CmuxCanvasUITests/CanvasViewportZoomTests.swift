import AppKit
import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas viewport zoom")
struct CanvasViewportZoomTests {
    @Test func discreteZoomOutAnimatesThenCommitsAroundCurrentCenter() throws {
        let root = makeRoot()
        root.shouldReduceMotionForDiscreteZoom = { false }
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)
        let centerBefore = root.currentCenterInCanvas

        root.zoom(by: 0.8)

        #expect(abs(root.currentMagnification - 0.8) < 0.0001)
        #expect(root.isDiscreteZoomAnimationActive)
        root.finishDiscreteZoomAnimation()

        #expect(abs(root.currentMagnification - 0.8) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerBefore.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerBefore.y) < 0.5)
    }

    @Test func reduceMotionZoomAppliesImmediately() throws {
        let root = makeRoot()
        root.shouldReduceMotionForDiscreteZoom = { true }
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)
        let centerBefore = root.currentCenterInCanvas

        root.zoom(by: 0.8)

        #expect(!root.isDiscreteZoomAnimationActive)
        #expect(abs(root.currentMagnification - 0.8) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerBefore.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerBefore.y) < 0.5)
    }

    @Test func repeatedDiscreteZoomOutClampsAtMinimumWithoutStackingAnimations() throws {
        let root = makeRoot()
        root.shouldReduceMotionForDiscreteZoom = { false }
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)

        for _ in 0..<12 {
            root.zoom(by: 1 / 1.25)
        }
        root.finishDiscreteZoomAnimation()

        #expect(abs(root.currentMagnification - root.scrollView.minMagnification) < 0.0001)
    }

    @Test func overviewCancelsPendingDiscreteZoomCompletion() throws {
        let root = makeRoot()
        root.shouldReduceMotionForDiscreteZoom = { false }
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)

        root.zoom(by: 0.8)
        #expect(root.isDiscreteZoomAnimationActive)

        root.toggleOverview()
        let magnificationAfterOverview = root.currentMagnification
        let centerAfterOverview = root.currentCenterInCanvas

        #expect(!root.isDiscreteZoomAnimationActive)
        root.finishDiscreteZoomAnimation()
        #expect(abs(root.currentMagnification - magnificationAfterOverview) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerAfterOverview.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerAfterOverview.y) < 0.5)
    }

    @Test func revealPaneCancelsPendingDiscreteZoomCompletion() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panelFrames: [
            (panelA, CGRect(x: 0, y: 0, width: 640, height: 360)),
            (panelB, CGRect(x: 1_600, y: 0, width: 640, height: 360)),
        ])
        root.shouldReduceMotionForDiscreteZoom = { false }
        root.setViewport(center: CGPoint(x: 320, y: 180), magnification: 1, notifySettled: false)

        root.zoom(by: 0.8)
        #expect(root.isDiscreteZoomAnimationActive)

        root.revealPane(panelB, animated: false)
        let centerAfterReveal = root.currentCenterInCanvas

        #expect(!root.isDiscreteZoomAnimationActive)
        root.finishDiscreteZoomAnimation()
        #expect(abs(root.currentCenterInCanvas.x - centerAfterReveal.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerAfterReveal.y) < 0.5)
    }

    @Test func lowZoomDiscreteZoomCommitsViewportBeforeAnimation() throws {
        let root = makeRoot()
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 0.262144, notifySettled: false)
        root.layoutSubtreeIfNeeded()

        let sourceMagnification = root.currentMagnification
        let targetMagnification = max(root.scrollView.minMagnification, sourceMagnification / 1.25)
        let centerBefore = root.currentCenterInCanvas

        root.zoom(by: 1 / 1.25)

        #expect(abs(root.currentMagnification - targetMagnification) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerBefore.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerBefore.y) < 0.5)

        let centerAfterCommit = root.currentCenterInCanvas
        root.finishDiscreteZoomAnimation()
        root.layoutSubtreeIfNeeded()

        #expect(abs(root.currentMagnification - targetMagnification) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerAfterCommit.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerAfterCommit.y) < 0.5)
    }

    @Test func lowZoomDiscreteZoomKeepsCenterWithTallViewportAndWideContent() throws {
        let root = makeRoot(
            panelFrames: [
                (UUID(), CGRect(x: 800, y: 0, width: 640, height: 420)),
                (UUID(), CGRect(x: 1456, y: 0, width: 640, height: 420)),
                (UUID(), CGRect(x: 2112, y: 0, width: 640, height: 420)),
                (UUID(), CGRect(x: 2768, y: 0, width: 640, height: 420)),
                (UUID(), CGRect(x: 3424, y: 0, width: 640, height: 420)),
                (UUID(), CGRect(x: 0, y: 0, width: 784, height: 672)),
                (UUID(), CGRect(x: -1208.72, y: 126, width: 640, height: 420)),
            ],
            hostSize: CGSize(width: 1700, height: 1200)
        )
        root.setViewport(center: CGPoint(x: 420, y: 610), magnification: 0.262144, notifySettled: false)
        root.layoutSubtreeIfNeeded()

        let sourceMagnification = root.currentMagnification
        let targetMagnification = max(root.scrollView.minMagnification, sourceMagnification / 1.25)
        let centerBefore = root.currentCenterInCanvas

        root.zoom(by: 1 / 1.25)

        #expect(abs(root.currentMagnification - targetMagnification) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerBefore.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerBefore.y) < 0.5)
    }

    private func makeRoot(
        panelFrames: [(UUID, CGRect)] = [(UUID(), CGRect(x: 0, y: 0, width: 640, height: 360))],
        hostSize: CGSize = CGSize(width: 800, height: 500)
    ) -> CanvasRootView {
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames(panelFrames.map { (id: $0.0, frame: $0.1) })
        let root = CanvasRootView(
            model: model,
            commandScrollHintText: "",
            minimapAccessibilityLabel: "",
            minimapAccessibilityHelp: "",
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { _ in },
                onClosePanel: { _ in },
                onLayoutChanged: {}
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .windowBackgroundColor, paneBackground: .windowBackgroundColor)
            },
            minimapClock: ContinuousClock()
        )
        let host = NSView(frame: CGRect(origin: .zero, size: hostSize))
        root.frame = host.bounds
        host.addSubview(root)
        root.layoutSubtreeIfNeeded()
        root.sync(
            descriptors: panelFrames.map { panel, _ in
                CanvasPaneDescriptor(
                    id: panel,
                    tab: CanvasTabChrome(id: panel, title: "A", iconSystemName: nil),
                    isFocused: true,
                    closeActionLabel: "",
                    makeMount: { _ in TestMount() }
                )
            },
            focusedPanelId: panelFrames.first?.0,
            isWorkspaceVisible: true
        )
        root.layoutSubtreeIfNeeded()
        return root
    }
}
