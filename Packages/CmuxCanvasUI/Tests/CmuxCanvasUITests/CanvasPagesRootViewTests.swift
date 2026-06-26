import AppKit
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("CanvasPagesRootView", .serialized)
struct CanvasPagesRootViewTests {
    @Test func pageIdentifiersAreStablePerPane() {
        let root = makeRoot()
        let paneID = CanvasPaneID(rawValue: UUID())
        let otherPaneID = CanvasPaneID(rawValue: UUID())

        let first = CanvasPageObject(pane: makePane(id: paneID))
        let recreated = CanvasPageObject(pane: makePane(id: paneID))
        let other = CanvasPageObject(pane: makePane(id: otherPaneID))

        let firstIdentifier = root.pageController(root.pageController, identifierFor: first)
        #expect(root.pageController(root.pageController, identifierFor: recreated) == firstIdentifier)
        #expect(root.pageController(root.pageController, identifierFor: other) != firstIdentifier)
    }

    @Test func controllersForRemovedPagesAreReleased() throws {
        let root = makeRoot()
        let page = CanvasPageObject(pane: makePane(id: CanvasPaneID(rawValue: UUID())))
        let identifier = root.pageController(root.pageController, identifierFor: page)
        weak var weakController: CanvasPageViewController?

        do {
            let controller = try #require(
                root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                    as? CanvasPageViewController
            )
            weakController = controller
            prepare(controller, with: page, in: root)

            root.pageObjects = []
            root.refreshPreparedControllers()
        }

        #expect(weakController == nil)
    }

    @Test func duplicateControllerForSamePageReplacesStaleMount() throws {
        let root = makeRoot()
        let paneID = CanvasPaneID(rawValue: UUID())
        let probe = MountProbe()
        root.sync(
            descriptors: [makeDescriptor(id: paneID.rawValue, probe: probe)],
            focusedPanelId: paneID.rawValue,
            isWorkspaceVisible: true
        )
        let page = try #require(root.pageObjects.first)
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let first = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        root.pageController(root.pageController, prepare: first, with: page)
        #expect(probe.mountCount > 0)

        let duplicate = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        #expect(first !== duplicate)
        root.pageController(root.pageController, prepare: duplicate, with: page)

        #expect(probe.unmountCount > 0)
        #expect(root.mountedPageObjects().map(\.paneID) == [paneID])
        #expect(root.renderedPanelIds.isEmpty)
    }

    @Test func reusedControllerMovesToNewPageWithoutStaleAlias() throws {
        let root = makeRoot()
        let first = CanvasPaneID(rawValue: UUID())
        let second = CanvasPaneID(rawValue: UUID())
        let firstProbe = MountProbe()
        let secondProbe = MountProbe()
        root.sync(
            descriptors: [
                makeDescriptor(id: first.rawValue, probe: firstProbe),
                makeDescriptor(id: second.rawValue, probe: secondProbe),
            ],
            focusedPanelId: first.rawValue,
            isWorkspaceVisible: true
        )
        let firstPage = try #require(root.pageObjects.first(where: { $0.paneID == first }))
        let secondPage = try #require(root.pageObjects.first(where: { $0.paneID == second }))
        let firstIdentifier = root.pageController(root.pageController, identifierFor: firstPage)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: firstIdentifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: firstPage, in: root)
        #expect(root.mountedPageObjects().map(\.paneID) == [first])

        root.pageController(root.pageController, prepare: controller, with: secondPage)

        #expect(firstProbe.unmountCount > 0)
        #expect(secondProbe.mountCount > 0)
        #expect(root.mountedPageObjects().map(\.paneID) == [second])
    }

    @Test func nilPagePrepareUnregistersReusedController() throws {
        let root = makeRoot()
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
        prepare(controller, with: page, in: root)
        #expect(root.mountedPageObjects().map(\.paneID) == [paneID])

        root.pageController(root.pageController, prepare: controller, with: nil)

        #expect(probe.unmountCount > 0)
        #expect(root.mountedPageObjects().isEmpty)
    }

    @Test func suppressedSelectionDoesNotFocusPageUntilTransitionEnds() {
        var focusedPanelId: UUID?
        let root = makeRoot(onFocusPanel: { focusedPanelId = $0 })
        let second = CanvasPageObject(pane: makePane(id: CanvasPaneID(rawValue: UUID())))
        root.isApplyingSyncSelection = true

        root.finishSelection(of: second)

        #expect(focusedPanelId == nil)
        #expect(root.isApplyingSyncSelection)

        root.pageControllerDidEndLiveTransition(root.pageController)
        #expect(!root.isApplyingSyncSelection)
    }

    @Test func descriptorArrivingAfterMissMountsPage() throws {
        let root = makeRoot()
        let paneID = CanvasPaneID(rawValue: UUID())
        let page = CanvasPageObject(pane: makePane(id: paneID))
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: page, in: root)

        let probe = MountProbe()
        root.sync(
            descriptors: [makeDescriptor(id: paneID.rawValue, probe: probe)],
            focusedPanelId: nil,
            isWorkspaceVisible: true
        )

        #expect(probe.mountCount > 0)
    }

    @Test func refreshEvictsVisitedControllersOutsideSelectedNeighborhood() throws {
        let root = makeRoot()
        let paneIDs = (0..<4).map { _ in CanvasPaneID(rawValue: UUID()) }
        let probes = Dictionary(uniqueKeysWithValues: paneIDs.map { ($0, MountProbe()) })
        root.sync(
            descriptors: paneIDs.map { paneID in
                makeDescriptor(id: paneID.rawValue, probe: probes[paneID]!)
            },
            focusedPanelId: paneIDs[1].rawValue,
            isWorkspaceVisible: true
        )
        let orderedPaneIDs = root.pageObjects.map(\.paneID)
        root.pageController.selectedIndex = 1

        weak var evictedController: CanvasPageViewController?
        var unmountCountsBeforeRefresh: [CanvasPaneID: Int] = [:]
        do {
            var strongEvictedController: CanvasPageViewController?
            for page in root.pageObjects {
                let paneID = page.paneID
                let identifier = root.pageController(root.pageController, identifierFor: page)
                let controller = try #require(
                    root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                        as? CanvasPageViewController
                )
                prepare(controller, with: page, in: root)
                if paneID == orderedPaneIDs[3] {
                    evictedController = controller
                    strongEvictedController = controller
                }
            }
            unmountCountsBeforeRefresh = Dictionary(
                uniqueKeysWithValues: orderedPaneIDs.map { paneID in
                    (paneID, probes[paneID]?.unmountCount ?? 0)
                }
            )

            root.refreshPreparedControllers()
            withExtendedLifetime(strongEvictedController) {}
            strongEvictedController = nil
        }

        #expect(probes[orderedPaneIDs[0]]?.unmountCount == unmountCountsBeforeRefresh[orderedPaneIDs[0]])
        #expect(probes[orderedPaneIDs[1]]?.unmountCount == unmountCountsBeforeRefresh[orderedPaneIDs[1]])
        #expect(probes[orderedPaneIDs[2]]?.unmountCount == unmountCountsBeforeRefresh[orderedPaneIDs[2]])
        #expect((probes[orderedPaneIDs[3]]?.unmountCount ?? 0) > (unmountCountsBeforeRefresh[orderedPaneIDs[3]] ?? 0))
        #expect(evictedController == nil)
    }

    @Test func renderedPanelIdsIncludeAttachedPagesOnly() throws {
        let root = makeRoot()
        let paneIDs = (0..<4).map { _ in CanvasPaneID(rawValue: UUID()) }
        let probes = Dictionary(uniqueKeysWithValues: paneIDs.map { ($0, MountProbe()) })
        root.sync(
            descriptors: paneIDs.map { paneID in
                makeDescriptor(id: paneID.rawValue, probe: probes[paneID]!)
            },
            focusedPanelId: paneIDs[1].rawValue,
            isWorkspaceVisible: true
        )
        root.pageController.selectedIndex = 1
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.pageController.view.frame = root.bounds
        defer { root.teardown() }

        let page = root.pageObjects[2]
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: page, in: root)
        #expect(probes[page.paneID]?.renderStates == [false])

        controller.view.frame = NSRect(
            x: root.pageController.view.bounds.maxX + 20,
            y: 0,
            width: 300,
            height: 200
        )
        root.pageController.view.addSubview(controller.view)
        root.updateControllerRendering()
        #expect(probes[page.paneID]?.renderStates == [false, false])
        #expect(!root.renderedPanelIds.contains(page.selectedPanelId))
        #expect(!controller.isRendered(in: root.pageController.view, requiresWindow: false))

        controller.view.frame = root.pageController.view.bounds.insetBy(dx: 20, dy: 20)
        root.updateControllerRendering()
        #expect(root.renderedPanelIds.isEmpty)
        #expect(controller.isRendered(in: root.pageController.view, requiresWindow: false))

        controller.view.removeFromSuperview()
        root.updateControllerRendering()
        #expect(!root.renderedPanelIds.contains(page.selectedPanelId))
        #expect(Array(probes[page.paneID]?.renderStates.suffix(3) ?? []) == [false, false, false])
    }

    @Test func renderedPanelIdChangesPublishViewportGeometry() throws {
        var geometryChangeCount = 0
        let root = makeRoot(onViewportGeometryChanged: { _ in geometryChangeCount += 1 })
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.pageController.view.frame = root.bounds
        defer { root.teardown() }

        let paneIDs = (0..<2).map { _ in CanvasPaneID(rawValue: UUID()) }
        root.sync(
            descriptors: paneIDs.map { makeDescriptor(id: $0.rawValue, probe: MountProbe()) },
            focusedPanelId: paneIDs[0].rawValue,
            isWorkspaceVisible: true
        )
        let page = root.pageObjects[1]
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: page, in: root)
        geometryChangeCount = 0

        controller.view.frame = root.pageController.view.bounds.insetBy(dx: 20, dy: 20)
        root.pageController.view.addSubview(controller.view)
        root.updateControllerRendering(requiresWindow: false)

        #expect(root.renderedPagePanelIds(requiresWindow: false).contains(page.selectedPanelId))
        #expect(geometryChangeCount == 1)

        controller.view.frame = NSRect(
            x: root.pageController.view.bounds.maxX + 20,
            y: 0,
            width: 300,
            height: 200
        )
        root.updateControllerRendering(requiresWindow: false)

        #expect(!root.renderedPagePanelIds(requiresWindow: false).contains(page.selectedPanelId))
        #expect(geometryChangeCount == 2)
    }

    @Test func revealSelectsPageWithoutPendingAnimatedTransition() {
        let root = makeRoot()
        let paneIDs = (0..<4).map { _ in CanvasPaneID(rawValue: UUID()) }
        root.sync(
            descriptors: paneIDs.map { makeDescriptor(id: $0.rawValue, probe: MountProbe()) },
            focusedPanelId: paneIDs[0].rawValue,
            isWorkspaceVisible: true
        )
        root.pageController.selectedIndex = 0

        let target = root.pageObjects[3]
        root.revealPane(target.selectedPanelId, animated: true)

        #expect(root.pageController.selectedIndex == 3)
        #expect(!root.isApplyingSyncSelection)
    }

    @Test func animatedExternalModelSyncDoesNotLeaveFocusSuppressed() {
        var focusedPanelId: UUID?
        let root = makeRoot(onFocusPanel: { focusedPanelId = $0 })
        let paneIDs = (0..<4).map { _ in CanvasPaneID(rawValue: UUID()) }
        root.sync(
            descriptors: paneIDs.map { makeDescriptor(id: $0.rawValue, probe: MountProbe()) },
            focusedPanelId: paneIDs[0].rawValue,
            isWorkspaceVisible: true
        )

        let target = root.pageObjects[2]
        root.latestFocusedPanelId = target.selectedPanelId
        root.modelDidChangeExternally(animated: true)

        #expect(root.pageController.selectedIndex == 2)
        #expect(!root.isApplyingSyncSelection)
        #expect(focusedPanelId == nil)
    }

    @Test func setViewportSelectsNearestPageAndPublishesGeometry() throws {
        var geometryChangeCount = 0
        let root = makeRoot(onViewportGeometryChanged: { _ in geometryChangeCount += 1 })
        let first = CanvasPaneID(rawValue: UUID())
        let second = CanvasPaneID(rawValue: UUID())
        let secondProbe = MountProbe()
        let descriptors = [
            makeDescriptor(id: first.rawValue, probe: MountProbe()),
            makeDescriptor(id: second.rawValue, probe: secondProbe),
        ]
        root.sync(
            descriptors: descriptors,
            focusedPanelId: first.rawValue,
            isWorkspaceVisible: true
        )
        root.model.setFrame(CGRect(x: 0, y: 0, width: 300, height: 200), for: first.rawValue)
        root.model.setFrame(CGRect(x: 1_000, y: 0, width: 300, height: 200), for: second.rawValue)
        root.modelDidChangeExternally(animated: false)

        let page = try #require(root.pageObjects.first(where: { $0.paneID == second }))
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: page, in: root)
        geometryChangeCount = 0

        root.setViewport(center: CGPoint(x: 1_150, y: 100), magnification: nil)

        #expect(root.pageController.selectedIndex == root.indexForPane(second))
        #expect(geometryChangeCount == 1)
        #expect(secondProbe.renderStates.allSatisfy { !$0 })

        root.sync(
            descriptors: descriptors,
            focusedPanelId: first.rawValue,
            isWorkspaceVisible: true
        )
        #expect(root.pageController.selectedIndex == root.indexForPane(second))
    }

    @Test func revealSelectsBackgroundTabBeforeRefreshingControllers() throws {
        let root = makeRoot()
        let first = UUID()
        let second = UUID()
        let firstProbe = MountProbe()
        let secondProbe = MountProbe()
        root.sync(
            descriptors: [
                makeDescriptor(id: first, probe: firstProbe),
                makeDescriptor(id: second, probe: secondProbe),
            ],
            focusedPanelId: first,
            isWorkspaceVisible: true
        )
        #expect(root.model.joinPanel(second, withPaneContaining: first))
        root.model.selectPanel(first)
        root.modelDidChangeExternally(animated: false)
        let page = try #require(root.pageObjects.first)
        let identifier = root.pageController(root.pageController, identifierFor: page)
        let controller = try #require(
            root.pageController(root.pageController, viewControllerForIdentifier: identifier)
                as? CanvasPageViewController
        )
        prepare(controller, with: page, in: root)
        #expect(firstProbe.mountCount > 0)
        #expect(secondProbe.mountCount == 0)

        root.revealPane(second, animated: true)

        #expect(root.pageObjects.first?.selectedPanelId == second)
        #expect(secondProbe.mountCount > 0)
        #expect(firstProbe.unmountCount > 0)
    }

    @Test func paneTitleBarScrollRequiresOverflow() {
        let pane = CanvasPaneView(paneID: CanvasPaneID(rawValue: UUID()))
        pane.frame = CGRect(x: 0, y: 0, width: 100, height: 120)

        pane.setMeasuredTabContentWidth(180)

        #expect(pane.canHandleTitleBarScroll(at: NSPoint(x: 12, y: 12), in: pane))
        #expect(!pane.canHandleTitleBarScroll(at: NSPoint(x: 12, y: CanvasPaneTitleBarView.height + 8), in: pane))

        pane.setMeasuredTabContentWidth(80)
        #expect(!pane.canHandleTitleBarScroll(at: NSPoint(x: 12, y: 12), in: pane))
    }

    @Test func inactivePagesRootDoesNotRoutePageScroll() {
        let root = makeRoot()
        defer { root.teardown() }
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let descriptors = [
            makeDescriptor(id: UUID(), probe: MountProbe()),
            makeDescriptor(id: UUID(), probe: MountProbe()),
        ]
        root.sync(descriptors: descriptors, focusedPanelId: nil, isWorkspaceVisible: false)

        #expect(!root.canRoutePageScroll(at: NSPoint(x: 100, y: 100)))

        root.sync(descriptors: descriptors, focusedPanelId: nil, isWorkspaceVisible: true)

        #expect(root.canRoutePageScroll(at: NSPoint(x: 100, y: 100)))
    }

    private func makeRoot(
        onFocusPanel: @escaping (UUID) -> Void = { _ in },
        onViewportGeometryChanged: @escaping (NSWindow?) -> Void = { _ in }
    ) -> CanvasPagesRootView {
        CanvasPagesRootView(
            model: CanvasModel(metricsProvider: {
                CanvasMetrics(gap: 16, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
            }),
            callbacks: CanvasHostCallbacks(
                onFocusPanel: onFocusPanel,
                onClosePanel: { _ in },
                onLayoutChanged: {},
                onViewportGeometryChanged: onViewportGeometryChanged
            ),
            themeProvider: {
                CanvasTheme(canvasBackground: .black, paneBackground: .black)
            }
        )
    }

    private func prepare(
        _ controller: CanvasPageViewController,
        with page: CanvasPageObject,
        in root: CanvasPagesRootView
    ) {
        root.pageController(root.pageController, prepare: controller, with: page)
    }

    private func makePane(id: CanvasPaneID) -> CanvasPane {
        CanvasPane(
            id: id,
            frame: CanvasRect(x: 0, y: 0, width: 300, height: 200)
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
