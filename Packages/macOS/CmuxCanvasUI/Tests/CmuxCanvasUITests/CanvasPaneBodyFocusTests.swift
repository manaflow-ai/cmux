import AppKit
import CoreGraphics
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas pane body focus", .serialized)
struct CanvasPaneBodyFocusTests {
    @Test func bodyMouseDownFocusPathRequestsFocusedPane() throws {
        let panelA = UUID()
        let panelB = UUID()
        var focusedPanels: [UUID] = []
        let root = makeRoot(panelA: panelA, panelB: panelB) { panelId in
            focusedPanels.append(panelId)
        }
        attachToHost(root)
        defer {
            root.teardown()
            root.removeFromSuperview()
        }

        let paneID = try #require(root.model.paneID(containing: panelB))
        let paneView = try #require(root.paneViews[paneID])
        let bodyPointInRoot = root.convert(
            CGPoint(x: paneView.contentContainer.bounds.midX, y: paneView.contentContainer.bounds.midY),
            from: paneView.contentContainer
        )

        #expect(root.focusPaneBody(fromRootMouseDownAt: bodyPointInRoot))
        #expect(focusedPanels == [panelB])
    }

    @Test func hiddenWorkspaceBodyMouseDownDoesNotRequestFocus() throws {
        let panelA = UUID()
        let panelB = UUID()
        var focusedPanels: [UUID] = []
        let root = makeRoot(panelA: panelA, panelB: panelB, isWorkspaceVisible: false) { panelId in
            focusedPanels.append(panelId)
        }
        attachToHost(root)
        defer {
            root.teardown()
            root.removeFromSuperview()
        }

        let paneID = try #require(root.model.paneID(containing: panelB))
        let paneView = try #require(root.paneViews[paneID])
        let bodyPointInRoot = root.convert(
            CGPoint(x: paneView.contentContainer.bounds.midX, y: paneView.contentContainer.bounds.midY),
            from: paneView.contentContainer
        )

        #expect(!root.focusPaneBody(fromRootMouseDownAt: bodyPointInRoot))
        #expect(focusedPanels.isEmpty)
    }

    @Test func minimapMouseDownDoesNotFocusPaneUnderOverlay() throws {
        let panelA = UUID()
        let panelB = UUID()
        var focusedPanels: [UUID] = []
        let root = makeRoot(panelA: panelA, panelB: panelB) { panelId in
            focusedPanels.append(panelId)
        }
        let overlayHost = attachToHost(root)
        defer {
            root.teardown()
            root.removeFromSuperview()
        }

        let paneID = try #require(root.model.paneID(containing: panelB))
        let paneView = try #require(root.paneViews[paneID])
        let bodyPointInRoot = root.convert(
            CGPoint(x: paneView.contentContainer.bounds.midX, y: paneView.contentContainer.bounds.midY),
            from: paneView.contentContainer
        )
        root.minimapView.removeFromSuperview()
        overlayHost.addSubview(root.minimapView, positioned: .above, relativeTo: nil)
        root.minimapView.frame = CGRect(
            x: bodyPointInRoot.x - 40,
            y: bodyPointInRoot.y - 30,
            width: 80,
            height: 60
        )
        root.minimapView.isHidden = false
        root.minimapView.alphaValue = 1

        #expect(!root.focusPaneBody(fromRootMouseDownAt: bodyPointInRoot))
        #expect(focusedPanels.isEmpty)
    }

    @discardableResult
    private func attachToHost(_ root: CanvasRootView) -> NSView {
        let host = NSView(frame: root.bounds)
        host.addSubview(root)
        root.frame = host.bounds
        root.layoutSubtreeIfNeeded()
        root.setViewport(center: CGPoint(x: 320, y: 110), magnification: 1, notifySettled: false)
        root.layoutSubtreeIfNeeded()
        return host
    }

    private func makeRoot(
        panelA: UUID,
        panelB: UUID,
        isWorkspaceVisible: Bool = true,
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
        root.frame = CGRect(x: 0, y: 0, width: 1_000, height: 360)
        root.layoutSubtreeIfNeeded()
        root.sync(
            descriptors: [
                descriptor(id: panelA, title: "A", focused: true),
                descriptor(id: panelB, title: "B", focused: false),
            ],
            focusedPanelId: panelA,
            isWorkspaceVisible: isWorkspaceVisible
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

}
