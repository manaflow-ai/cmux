import AppKit
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

#if DEBUG
@MainActor
@Suite("Canvas command-scroll hint")
struct CanvasCommandScrollHintTests {
    @Test func debugPresentationRepeatsWithoutConsumingOneTimeDiscoveryFlag() {
        let panelID = UUID()
        let root = makeRoot(panelID: panelID)
        defer {
            root.teardown()
            CanvasRootView.didShowCommandScrollHintThisSession = false
        }
        CanvasRootView.didShowCommandScrollHintThisSession = false

        root.debugShowCommandScrollHint()
        guard let firstHost = root.commandScrollHintHost else {
            Issue.record("expected first hint host")
            return
        }
        #expect(!CanvasRootView.didShowCommandScrollHintThisSession)

        root.debugShowCommandScrollHint()
        guard let secondHost = root.commandScrollHintHost else {
            Issue.record("expected replacement hint host")
            return
        }
        #expect(firstHost !== secondHost)
        #expect(firstHost.superview == nil)
        #expect(!CanvasRootView.didShowCommandScrollHintThisSession)

        secondHost.removeFromSuperview()
        root.commandScrollHintHost = nil
        root.presentCommandScrollHint()

        #expect(CanvasRootView.didShowCommandScrollHintThisSession)
    }

    @Test func inPaneScrollDoesNotCancelVisibleDebugHintDismissal() {
        let panelID = UUID()
        let root = makeRoot(panelID: panelID)
        defer {
            root.teardown()
            CanvasRootView.didShowCommandScrollHintThisSession = false
        }
        CanvasRootView.didShowCommandScrollHintThisSession = false

        root.debugShowCommandScrollHint()
        #expect(root.commandScrollHintHost != nil)

        root.commandScrollHintTask?.cancel()
        let dismissalTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        root.commandScrollHintTask = dismissalTask

        root.noteInPaneScrollForHint()

        #expect(!dismissalTask.isCancelled)
        dismissalTask.cancel()
    }

    private func makeRoot(panelID: UUID) -> CanvasRootView {
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames([
            (id: panelID, frame: CGRect(x: 0, y: 0, width: 300, height: 220)),
        ])
        let root = CanvasRootView(
            model: model,
            commandScrollHintText: "Command+scroll pans the canvas from anywhere",
            minimapAccessibilityLabel: "Canvas minimap",
            minimapAccessibilityHelp: "Click or drag to move the canvas viewport",
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { _ in },
                onClosePanel: { _ in },
                onLayoutChanged: {}
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .windowBackgroundColor, paneBackground: .windowBackgroundColor)
            }
        )
        root.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        root.layoutSubtreeIfNeeded()
        root.sync(
            descriptors: [
                CanvasPaneDescriptor(
                    id: panelID,
                    tab: CanvasTabChrome(id: panelID, title: "A", iconSystemName: nil),
                    isFocused: true,
                    closeActionLabel: "",
                    makeMount: { _ in TestMount() }
                ),
            ],
            focusedPanelId: panelID,
            isWorkspaceVisible: true
        )
        root.layoutSubtreeIfNeeded()
        return root
    }
}
#endif
