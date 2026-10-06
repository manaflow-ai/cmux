import AppKit
import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas theme backdrop")
struct CanvasThemeBackdropTests {
    @Test func opaqueThemeFillsCanvasAndPanes() throws {
        let root = makeRoot(theme: CanvasTheme(canvasBackground: .black, paneBackground: .black))
        let pane = try #require(root.paneViews.values.first)

        #expect(root.scrollView.drawsBackground)
        #expect(root.documentView.isOpaque)
        #expect(pane.layer?.backgroundColor?.alpha == 1)
    }

    @Test func windowBackdropThemeLeavesCanvasAndPanesClear() throws {
        let root = makeRoot(theme: CanvasTheme(
            canvasBackground: .black,
            paneBackground: .black,
            showsWindowBackdrop: true
        ))
        let pane = try #require(root.paneViews.values.first)

        #expect(!root.scrollView.drawsBackground)
        #expect(!root.documentView.isOpaque)
        #expect((pane.layer?.backgroundColor?.alpha ?? 0) == 0)
    }

    private func makeRoot(theme: CanvasTheme) -> CanvasRootView {
        let panel = UUID()
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames([(id: panel, frame: CGRect(x: 0, y: 0, width: 640, height: 360))])
        let root = CanvasRootView(
            model: model,
            commandScrollHintText: "",
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { _ in },
                onClosePanel: { _ in },
                onLayoutChanged: {}
            ),
            themeProvider: { theme }
        )
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        root.frame = host.bounds
        host.addSubview(root)
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
