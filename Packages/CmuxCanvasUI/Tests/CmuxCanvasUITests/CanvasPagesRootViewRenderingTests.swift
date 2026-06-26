import AppKit
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("CanvasPagesRootView rendering", .serialized)
struct CanvasPagesRootViewRenderingTests {
    @Test func layoutReconcilesRenderingAfterPageViewReceivesGeometry() throws {
        let root = makeRoot()
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.pageController.view.frame = root.bounds
        defer { root.teardown() }

        let paneID = CanvasPaneID(rawValue: UUID())
        let probe = MountProbe()
        root.sync(
            descriptors: [makeDescriptor(id: paneID.rawValue, probe: probe)],
            focusedPanelId: paneID.rawValue,
            isWorkspaceVisible: true
        )
        let page = try #require(root.pageObjects.first)
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        root.pageController(root.pageController, prepare: controller, with: page)
        root.pageController.view.addSubview(controller.view)
        controller.view.frame = .zero
        root.updateControllerRendering()
        #expect(probe.renderStates.last == false)

        controller.view.frame = root.pageController.view.bounds.insetBy(dx: 20, dy: 20)
        root.reconcileRenderingAfterLayout(requiresWindow: false)

        #expect(probe.renderStates.last == true)
        #expect(root.renderedPagePanelIds(requiresWindow: false) == Set([page.selectedPanelId]))
    }

    private func makeRoot() -> CanvasPagesRootView {
        CanvasPagesRootView(
            model: CanvasModel(metricsProvider: {
                CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
            }),
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { _ in },
                onClosePanel: { _ in },
                onLayoutChanged: {},
                onViewportGeometryChanged: { _ in }
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .black, paneBackground: .black)
            }
        )
    }

    private func makeDescriptor(id: UUID, probe: MountProbe) -> CanvasPaneDescriptor {
        CanvasPaneDescriptor(
            id: id,
            tab: CanvasTabChrome(id: id, title: "Terminal", iconSystemName: "terminal"),
            isFocused: false,
            closeActionLabel: "Close",
            makeMount: { container in
                probe.mountCount += 1
                return FakeMount(container: container, probe: probe)
            }
        )
    }
}
