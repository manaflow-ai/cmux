import AppKit
import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

/// Viewport and pane-frame motion: panes the user did not create must not
/// pull the viewport, and Reduce Motion turns every pan and frame animation
/// into an immediate move.
@MainActor
@Suite("Canvas viewport motion")
struct CanvasViewportMotionTests {
    @Test func unfocusedAddedPaneDoesNotMoveViewport() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA], focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }
        let originBefore = visibleRect(root).origin

        root.sync(descriptors: descriptors([panelA, panelB]), focusedPanelId: panelA, isWorkspaceVisible: true)
        let paneB = try #require(root.model.frame(of: panelB))
        #expect(!visibleRect(root).contains(root.documentRect(fromCanvas: paneB)))
        settleAnimations()

        #expect(visibleRect(root).origin == originBefore)
        #expect(animations.isEmpty)
    }

    @Test func focusedAddedPaneIsRevealedWithoutAnimation() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA], focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }

        root.sync(descriptors: descriptors([panelA, panelB]), focusedPanelId: panelB, isWorkspaceVisible: true)

        let paneB = try #require(root.model.frame(of: panelB))
        #expect(visibleRect(root).contains(root.documentRect(fromCanvas: paneB)))
        #expect(animations.isEmpty)
    }

    @Test func revealPaneAnimatesWhenMotionIsAllowed() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA, panelB], frames: farApartFrames(panelA, panelB), focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }

        root.revealPane(panelB, animated: true)

        #expect(animations == [CanvasRootView.panAnimationDuration])
    }

    @Test func reduceMotionRevealsPaneImmediately() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA, panelB], frames: farApartFrames(panelA, panelB), focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { true }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }

        root.revealPane(panelB, animated: true)

        let paneB = try #require(root.model.frame(of: panelB))
        #expect(visibleRect(root).contains(root.documentRect(fromCanvas: paneB)))
        #expect(animations.isEmpty)
    }

    @Test func reduceMotionAppliesExternalFrameChangesImmediately() throws {
        let panelA = UUID()
        let root = makeRoot(panels: [panelA], focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { true }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }
        let paneView = try #require(root.paneViews[CanvasPaneID(rawValue: panelA)])

        root.model.setFrame(CGRect(x: 40, y: 30, width: 500, height: 300), for: panelA)
        root.modelDidChangeExternally(animated: true)

        let target = try #require(root.model.frame(of: panelA))
        #expect(paneView.frame == root.documentRect(fromCanvas: target))
        #expect(animations.isEmpty)
    }

    @Test func externalFrameChangesAnimateWhenMotionIsAllowed() throws {
        let panelA = UUID()
        let root = makeRoot(panels: [panelA], focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }

        root.model.setFrame(CGRect(x: 40, y: 30, width: 500, height: 300), for: panelA)
        root.modelDidChangeExternally(animated: true)

        #expect(animations == [CanvasRootView.paneFrameAnimationDuration])
    }

    @Test func reduceMotionTogglesOverviewImmediately() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA, panelB], frames: farApartFrames(panelA, panelB), focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { true }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }
        let magnificationBefore = root.currentMagnification

        root.toggleOverview()

        let paneB = try #require(root.model.frame(of: panelB))
        #expect(root.currentMagnification < magnificationBefore)
        #expect(visibleRect(root).contains(root.documentRect(fromCanvas: paneB)))

        root.toggleOverview()

        #expect(abs(root.currentMagnification - magnificationBefore) < 0.0001)
        #expect(animations.isEmpty)
    }

    @Test func overviewAnimatesWhenMotionIsAllowed() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA, panelB], frames: farApartFrames(panelA, panelB), focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }

        root.toggleOverview()

        #expect(animations == [CanvasRootView.overviewAnimationDuration])
    }

    @Test func unanimatedOverviewAndZoomSkipAnimationWhenMotionIsAllowed() throws {
        let panelA = UUID()
        let panelB = UUID()
        let root = makeRoot(panels: [panelA, panelB], frames: farApartFrames(panelA, panelB), focused: panelA)
        defer { root.teardown() }
        root.shouldReduceMotion = { false }
        var animations: [TimeInterval] = []
        root.onMotionAnimationStarted = { animations.append($0) }
        let magnificationBefore = root.currentMagnification

        root.toggleOverview(animated: false)
        #expect(root.currentMagnification < magnificationBefore)
        root.toggleOverview(animated: false)
        root.zoom(by: 0.8, animated: false)

        #expect(abs(root.currentMagnification - magnificationBefore * 0.8) < 0.0001)
        #expect(!root.isDiscreteZoomAnimationActive)
        #expect(animations.isEmpty)
    }

    // MARK: Helpers

    private func farApartFrames(_ first: UUID, _ second: UUID) -> [UUID: CGRect] {
        [
            first: CGRect(x: 0, y: 0, width: 640, height: 360),
            second: CGRect(x: 1_600, y: 0, width: 640, height: 360),
        ]
    }

    private func visibleRect(_ root: CanvasRootView) -> CGRect {
        root.scrollView.contentView.documentVisibleRect
    }

    /// Lets any running implicit animation finish (the canvas pan is 0.28 s).
    private func settleAnimations() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private func descriptors(_ panels: [UUID]) -> [CanvasPaneDescriptor] {
        panels.map { panel in
            CanvasPaneDescriptor(
                id: panel,
                tab: CanvasTabChrome(id: panel, title: "Pane", iconSystemName: nil),
                isFocused: false,
                closeActionLabel: "",
                makeMount: { _ in TestMount() }
            )
        }
    }

    private func makeRoot(
        panels: [UUID],
        frames: [UUID: CGRect] = [:],
        focused: UUID
    ) -> CanvasRootView {
        let model = CanvasModel(metricsProvider: {
            CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
        model.restoreFrames(panels.map { panel in
            (id: panel, frame: frames[panel] ?? CGRect(x: 0, y: 0, width: 640, height: 360))
        })
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
        root.sync(descriptors: descriptors(panels), focusedPanelId: focused, isWorkspaceVisible: true)
        root.layoutSubtreeIfNeeded()
        return root
    }
}
