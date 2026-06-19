import AppKit
import CoreGraphics
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas pane body focus")
struct CanvasPaneBodyFocusTests {
    @Test func bodyMouseDownRequestsFocusBeforeContentReceivesEvent() throws {
        let panelA = UUID()
        let panelB = UUID()
        var focusedPanels: [UUID] = []
        let root = makeRoot(panelA: panelA, panelB: panelB) { panelId in
            focusedPanels.append(panelId)
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.orderFrontRegardless()
        defer {
            root.teardown()
            window.close()
        }

        let paneID = try #require(root.model.paneID(containing: panelB))
        let paneView = try #require(root.paneViews[paneID])
        let bodyPointInRoot = root.convert(
            CGPoint(x: paneView.contentContainer.bounds.midX, y: paneView.contentContainer.bounds.midY),
            from: paneView.contentContainer
        )

        NSApp.sendEvent(mouseEvent(location: bodyPointInRoot, windowNumber: window.windowNumber))

        #expect(focusedPanels == [panelB])
    }

    private func makeRoot(
        panelA: UUID,
        panelB: UUID,
        onFocusPanel: @escaping (UUID) -> Void
    ) -> CanvasRootView {
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames([
            (id: panelA, frame: CGRect(x: 0, y: 0, width: 300, height: 220)),
            (id: panelB, frame: CGRect(x: 340, y: 0, width: 300, height: 220)),
        ])
        let root = CanvasRootView(
            model: model,
            commandScrollHintText: "",
            minimapAccessibilityLabel: "",
            minimapAccessibilityHelp: "",
            callbacks: CanvasHostCallbacks(
                onFocusPanel: onFocusPanel,
                onClosePanel: { _ in },
                onLayoutChanged: {}
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .windowBackgroundColor, paneBackground: .windowBackgroundColor)
            },
            minimapClock: ContinuousClock()
        )
        root.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        root.layoutSubtreeIfNeeded()
        root.sync(
            descriptors: [
                descriptor(id: panelA, title: "A", focused: true),
                descriptor(id: panelB, title: "B", focused: false),
            ],
            focusedPanelId: panelA,
            isWorkspaceVisible: true
        )
        root.layoutSubtreeIfNeeded()
        return root
    }

    private func descriptor(id: UUID, title: String, focused: Bool) -> CanvasPaneDescriptor {
        CanvasPaneDescriptor(
            id: id,
            tab: CanvasTabChrome(id: id, title: title, iconSystemName: nil),
            isFocused: focused,
            closeActionLabel: "",
            makeMount: { _ in TestMount() }
        )
    }

    private func mouseEvent(location: CGPoint, windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
