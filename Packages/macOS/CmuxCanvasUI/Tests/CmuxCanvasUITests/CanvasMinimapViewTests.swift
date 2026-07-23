import AppKit
import CoreGraphics
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("CanvasMinimapView")
struct CanvasMinimapViewTests {
    @Test func paneDragRevealsMinimap() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }

        root.resetMinimapVisibility()
        #expect(root.minimapView.isHidden)

        let paneID = root.model.paneID(containing: panelA)!
        let paneView = root.paneViews[paneID]!
        root.paneView(paneView, mouseDownAt: CGPoint(x: 20, y: 10), region: .titleBar)
        root.paneView(paneView, draggedTo: CGPoint(x: 64, y: 18), modifiers: [])

        #expect(!root.minimapView.isHidden)
        #expect(root.minimapView.alphaValue > 0)
    }

    @Test func paneDragKeepsMinimapPinnedUntilDrop() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }

        root.resetMinimapVisibility()
        let paneID = root.model.paneID(containing: panelA)!
        let paneView = root.paneViews[paneID]!
        root.paneView(paneView, mouseDownAt: CGPoint(x: 20, y: 10), region: .titleBar)
        root.paneView(paneView, draggedTo: CGPoint(x: 64, y: 18), modifiers: [])

        #expect(root.isMinimapInteractionActive)
        #expect(!root.minimapAutoHideScheduler.hasPendingHide)

        root.paneViewDidEndDrag(paneView)

        #expect(!root.isMinimapInteractionActive)
        #expect(root.minimapAutoHideScheduler.hasPendingHide)
    }

    @Test func paneDragDefersViewportGeometryCallbackUntilDrop() {
        let panelA = UUID()
        let panelB = UUID()
        var viewportGeometryChangeCount = 0
        let root = makeRootWithMinimapContent(
            panelA: panelA,
            panelB: panelB,
            onViewportGeometryChanged: { _ in
                viewportGeometryChangeCount += 1
            }
        )
        defer {
            root.teardown()
        }
        viewportGeometryChangeCount = 0

        let paneID = root.model.paneID(containing: panelA)!
        let paneView = root.paneViews[paneID]!
        root.paneView(paneView, mouseDownAt: CGPoint(x: 20, y: 10), region: .titleBar)
        root.paneView(paneView, draggedTo: CGPoint(x: 64, y: 18), modifiers: [])
        root.paneView(paneView, draggedTo: CGPoint(x: 96, y: 30), modifiers: [])
        root.paneView(paneView, draggedTo: CGPoint(x: 128, y: 44), modifiers: [])

        #expect(viewportGeometryChangeCount == 0)

        root.paneViewDidEndDrag(paneView)

        #expect(viewportGeometryChangeCount > 0)
    }

    @Test func lowZoomPaneDragSuppressesContentUntilDrop() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }
        root.scrollView.magnification = CanvasRootView.dragContentSuppressionMagnificationThreshold - 0.01

        let paneID = root.model.paneID(containing: panelA)!
        let paneView = root.paneViews[paneID]!
        root.paneView(paneView, mouseDownAt: CGPoint(x: 20, y: 10), region: .titleBar)

        #expect(paneView.isContentSuppressedForDrag)
        #expect(paneView.contentContainer.isHidden)

        root.paneViewDidEndDrag(paneView)

        #expect(!paneView.isContentSuppressedForDrag)
        #expect(!paneView.contentContainer.isHidden)
    }

    @Test func normalZoomPaneDragKeepsContentVisible() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }
        root.scrollView.magnification = CanvasRootView.dragContentSuppressionMagnificationThreshold

        let paneID = root.model.paneID(containing: panelA)!
        let paneView = root.paneViews[paneID]!
        root.paneView(paneView, mouseDownAt: CGPoint(x: 20, y: 10), region: .titleBar)

        #expect(!paneView.isContentSuppressedForDrag)
        #expect(!paneView.contentContainer.isHidden)
    }

    @Test func minimapDragRecenterDoesNotScheduleAutoHideUntilRelease() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }
        root.holdMinimapVisible()

        root.minimapView.mouseDown(
            with: mouseEvent(
                type: .leftMouseDown,
                location: minimapWindowPoint(root, CGPoint(x: 40, y: 40))
            )
        )

        #expect(root.isMinimapInteractionActive)
        #expect(!root.minimapAutoHideScheduler.hasPendingHide)

        root.minimapView.mouseUp(
            with: mouseEvent(
                type: .leftMouseUp,
                location: minimapWindowPoint(root, CGPoint(x: root.minimapView.bounds.maxX + 24, y: 40))
            )
        )

        #expect(!root.isMinimapInteractionActive)
        #expect(root.minimapAutoHideScheduler.hasPendingHide)
    }

    @Test func resetClearsMinimapViewInteractionStateBeforeNextDrag() {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRootWithMinimapContent(panelA: panelA, panelB: panelB)
        defer {
            root.teardown()
        }
        root.holdMinimapVisible()
        root.minimapView.mouseEntered(
            with: mouseEvent(
                type: .mouseMoved,
                location: minimapWindowPoint(root, CGPoint(x: 40, y: 40))
            )
        )

        root.resetMinimapVisibility()
        root.updateMinimap(reveal: true)

        #expect(root.minimapAutoHideScheduler.hasPendingHide)

        root.minimapView.mouseDown(
            with: mouseEvent(
                type: .leftMouseDown,
                location: minimapWindowPoint(root, CGPoint(x: 44, y: 42))
            )
        )

        #expect(root.isMinimapInteractionActive)
        #expect(!root.minimapAutoHideScheduler.hasPendingHide)
    }

    @Test func overlayFrameShrinksInsideNarrowRoot() {
        let frame = CanvasRootView.minimapOverlayFrame(
            rootRect: CGRect(x: 0, y: 0, width: 150, height: 100),
            containerIsFlipped: true
        )

        #expect(frame == CGRect(x: 14, y: 14, width: 122, height: 72))
    }

    @Test func overlayFrameIsNilWhenRootCannotFitUsableMinimap() {
        let frame = CanvasRootView.minimapOverlayFrame(
            rootRect: CGRect(x: 0, y: 0, width: 110, height: 80),
            containerIsFlipped: true
        )

        #expect(frame == nil)
    }

    @Test func hoverKeepsInteractionActiveAfterMouseUpInside() {
        let view = CanvasMinimapView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        view.snapshot = CanvasMinimapSnapshot(
            panes: [
                CanvasMinimapPaneSnapshot(
                    id: CanvasPaneID(rawValue: UUID()),
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                ),
            ],
            visibleRect: CGRect(x: 100, y: 100, width: 200, height: 160),
            focusedPaneID: nil
        )
        var beganCount = 0
        var endedCount = 0
        view.onInteractionBegan = { beganCount += 1 }
        view.onInteractionEnded = { endedCount += 1 }

        view.mouseEntered(with: mouseEvent(type: .mouseMoved, location: CGPoint(x: 40, y: 40)))
        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 40, y: 40)))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 100, y: 70)))

        #expect(beganCount == 1)
        #expect(endedCount == 0)

        view.mouseExited(with: mouseEvent(type: .mouseMoved, location: CGPoint(x: 180, y: 70)))

        #expect(beganCount == 1)
        #expect(endedCount == 1)
    }

    @Test func dragExitEndsInteractionOnlyAfterMouseUpOutside() {
        let view = CanvasMinimapView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        view.snapshot = CanvasMinimapSnapshot(
            panes: [
                CanvasMinimapPaneSnapshot(
                    id: CanvasPaneID(rawValue: UUID()),
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                ),
            ],
            visibleRect: CGRect(x: 100, y: 100, width: 200, height: 160),
            focusedPaneID: nil
        )
        var beganCount = 0
        var endedCount = 0
        view.onInteractionBegan = { beganCount += 1 }
        view.onInteractionEnded = { endedCount += 1 }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 40, y: 40)))
        view.mouseExited(with: mouseEvent(type: .mouseMoved, location: CGPoint(x: 180, y: 70)))

        #expect(beganCount == 1)
        #expect(endedCount == 0)

        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 180, y: 70)))

        #expect(beganCount == 1)
        #expect(endedCount == 1)
    }

    @Test func dragSettlesOnlyOnMouseUp() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let view = CanvasMinimapView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        view.snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 100, y: 100, width: 200, height: 160),
            focusedPaneID: nil
        )
        var changedCenters: [CGPoint] = []
        var settledCenters: [CGPoint] = []
        view.onCenterChanged = { changedCenters.append($0) }
        view.onCenterSettled = { settledCenters.append($0) }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 40, y: 40)))
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 80, y: 60)))

        #expect(changedCenters.count == 2)
        #expect(settledCenters.isEmpty)

        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 100, y: 70)))

        #expect(changedCenters.count == 2)
        #expect(settledCenters.count == 1)
    }

    private func makeRootWithMinimapContent(panelA: UUID, panelB: UUID) -> CanvasRootView {
        makeRootWithMinimapContent(
            panelA: panelA,
            panelB: panelB,
            onViewportGeometryChanged: { _ in },
            minimapClock: ContinuousClock()
        )
    }

    private func makeRootWithMinimapContent(
        panelA: UUID,
        panelB: UUID,
        onViewportGeometryChanged: @escaping (NSWindow?) -> Void
    ) -> CanvasRootView {
        makeRootWithMinimapContent(
            panelA: panelA,
            panelB: panelB,
            onViewportGeometryChanged: onViewportGeometryChanged,
            minimapClock: ContinuousClock()
        )
    }

    private func makeRootWithMinimapContent<C: Clock & Sendable>(
        panelA: UUID,
        panelB: UUID,
        onViewportGeometryChanged: @escaping (NSWindow?) -> Void = { _ in },
        minimapClock: C
    ) -> CanvasRootView where C.Duration == Duration {
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames([
            (id: panelA, frame: CGRect(x: 0, y: 0, width: 300, height: 220)),
            (id: panelB, frame: CGRect(x: 520, y: 0, width: 300, height: 220)),
        ])
        let root = CanvasRootView(
            model: model,
            commandScrollHintText: "",
            minimapAccessibilityLabel: "Canvas minimap",
            minimapAccessibilityHelp: "Click or drag to move the canvas viewport",
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { _ in },
                onClosePanel: { _ in },
                onLayoutChanged: {},
                onViewportGeometryChanged: onViewportGeometryChanged
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .windowBackgroundColor, paneBackground: .windowBackgroundColor)
            },
            minimapClock: minimapClock
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

    private func minimapWindowPoint(_ root: CanvasRootView, _ point: CGPoint) -> CGPoint {
        CGPoint(x: root.minimapView.frame.minX + point.x, y: root.minimapView.frame.minY + point.y)
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
