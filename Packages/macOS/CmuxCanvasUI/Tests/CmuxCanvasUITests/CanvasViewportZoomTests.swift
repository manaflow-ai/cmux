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

        #expect(root.currentMagnification == 1)
        #expect(root.pendingDiscreteZoomAnimation?.magnification == 0.8)
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

        #expect(root.pendingDiscreteZoomAnimation == nil)
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
        #expect(root.pendingDiscreteZoomAnimation != nil)

        root.toggleOverview()
        let magnificationAfterOverview = root.currentMagnification
        let centerAfterOverview = root.currentCenterInCanvas

        #expect(root.pendingDiscreteZoomAnimation == nil)
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
        #expect(root.pendingDiscreteZoomAnimation != nil)

        root.revealPane(panelB, animated: false)
        let centerAfterReveal = root.currentCenterInCanvas

        #expect(root.pendingDiscreteZoomAnimation == nil)
        root.finishDiscreteZoomAnimation()
        #expect(abs(root.currentCenterInCanvas.x - centerAfterReveal.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerAfterReveal.y) < 0.5)
    }

    private func makeRoot(
        panelFrames: [(UUID, CGRect)] = [(UUID(), CGRect(x: 0, y: 0, width: 640, height: 360))]
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
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
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
