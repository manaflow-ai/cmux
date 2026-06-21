import AppKit
import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas viewport zoom")
struct CanvasViewportZoomTests {
    @Test func discreteZoomOutAppliesSynchronouslyAroundCurrentCenter() throws {
        let root = makeRoot()
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)
        let centerBefore = root.currentCenterInCanvas

        root.zoom(by: 0.8)

        #expect(abs(root.currentMagnification - 0.8) < 0.0001)
        #expect(abs(root.currentCenterInCanvas.x - centerBefore.x) < 0.5)
        #expect(abs(root.currentCenterInCanvas.y - centerBefore.y) < 0.5)
    }

    @Test func repeatedDiscreteZoomOutClampsAtMinimumSynchronously() throws {
        let root = makeRoot()
        root.setViewport(center: CGPoint(x: 420, y: 180), magnification: 1, notifySettled: false)

        for _ in 0..<12 {
            root.zoom(by: 1 / 1.25)
        }

        #expect(abs(root.currentMagnification - root.scrollView.minMagnification) < 0.0001)
    }

    private func makeRoot() -> CanvasRootView {
        let panel = UUID()
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames([
            (id: panel, frame: CGRect(x: 0, y: 0, width: 640, height: 360)),
        ])
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
            descriptors: [
                CanvasPaneDescriptor(
                    id: panel,
                    tab: CanvasTabChrome(id: panel, title: "A", iconSystemName: nil),
                    isFocused: true,
                    closeActionLabel: "",
                    makeMount: { _ in TestMount() }
                ),
            ],
            focusedPanelId: panel,
            isWorkspaceVisible: true
        )
        root.layoutSubtreeIfNeeded()
        return root
    }
}
