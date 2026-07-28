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

    @Test func paneViewBodyMouseDownDoesNotRequestSecondFocus() throws {
        let paneView = CanvasPaneView(paneID: CanvasPaneID(rawValue: UUID()))
        let delegate = CanvasPaneDelegateSpy()
        paneView.delegate = delegate
        paneView.frame = CGRect(x: 0, y: 0, width: 300, height: 220)
        paneView.layoutSubtreeIfNeeded()

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: paneView.bounds.midX, y: paneView.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        paneView.mouseDown(with: event)

        #expect(delegate.focusRequests.isEmpty)
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

    @Test func sameWindowOverlayAboveCanvasDoesNotFocusUnderlyingPane() throws {
        let panelA = UUID()
        let panelB = UUID()
        var focusedPanels: [UUID] = []
        let root = makeRoot(panelA: panelA, panelB: panelB) { panelId in
            focusedPanels.append(panelId)
        }
        let host = attachToHost(root)
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
        let overlay = NSView(frame: CGRect(
            x: bodyPointInRoot.x - 30,
            y: bodyPointInRoot.y - 30,
            width: 60,
            height: 60
        ))
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.addSubview(overlay, positioned: .above, relativeTo: nil)

        #expect(!root.focusPaneBody(fromRootMouseDownAt: bodyPointInRoot, topHitView: overlay))
        #expect(focusedPanels.isEmpty)
    }

    @Test func descriptorSyncUpdatesMountedContentPresentationState() throws {
        let panelA = UUID()
        let panelB = UUID()
        var mountsByPanelId: [UUID: TestMount] = [:]
        let root = makeRoot(panelA: panelA, panelB: panelB, mountFactory: { panelId in
            let mount = TestMount()
            mountsByPanelId[panelId] = mount
            return mount
        }) { _ in }
        attachToHost(root)
        defer {
            root.teardown()
            root.removeFromSuperview()
        }

        let panelAMount = try #require(mountsByPanelId[panelA])
        let panelBMount = try #require(mountsByPanelId[panelB])
        #expect(panelAMount.focusedStates.last == true)
        #expect(panelAMount.inactiveOverlayStates.last == false)
        #expect(panelBMount.focusedStates.last == false)
        #expect(panelBMount.inactiveOverlayStates.last == true)

        root.sync(
            descriptors: [
                descriptor(id: panelA, title: "A", focused: false),
                descriptor(id: panelB, title: "B", focused: true),
            ],
            focusedPanelId: panelB,
            isWorkspaceVisible: true
        )

        #expect(panelAMount.focusedStates.last == false)
        #expect(panelAMount.inactiveOverlayStates.last == true)
        #expect(panelBMount.focusedStates.last == true)
        #expect(panelBMount.inactiveOverlayStates.last == false)
    }

    @Test func tabSelectionWaitsForFreshDescriptorBeforeUpdatingMountPresentation() throws {
        let panelA = UUID()
        let panelB = UUID()
        var mountsByPanelId: [UUID: TestMount] = [:]
        let root = makeRoot(panelA: panelA, panelB: panelB, mountFactory: { panelId in
            let mount = TestMount()
            mountsByPanelId[panelId] = mount
            return mount
        }) { _ in }
        attachToHost(root)
        defer {
            root.teardown()
            root.removeFromSuperview()
        }
        #expect(root.model.joinPanel(panelB, withPaneContaining: panelA))
        root.model.selectPanel(panelA)
        root.reconcilePanes()
        mountsByPanelId.removeAll()

        let paneID = try #require(root.model.paneID(containing: panelB))
        let paneView = try #require(root.paneViews[paneID])
        root.paneView(paneView, didSelectTab: panelB)

        let panelBMount = try #require(mountsByPanelId[panelB])
        #expect(panelBMount.focusedStates.isEmpty)
        #expect(panelBMount.inactiveOverlayStates.isEmpty)

        root.sync(
            descriptors: [
                descriptor(id: panelA, title: "A", focused: false),
                descriptor(id: panelB, title: "B", focused: true),
            ],
            focusedPanelId: panelB,
            isWorkspaceVisible: true
        )

        #expect(panelBMount.focusedStates == [true])
        #expect(panelBMount.inactiveOverlayStates == [false])
    }

    @Test func tabHitTesterUsesRenderedTabOrderInsteadOfDictionaryOrder() {
        let panelA = UUID()
        let panelB = UUID()
        let tester = CanvasTabHitTester(
            tabOrder: [panelA, panelB],
            hitRegions: CanvasTabHitRegions(
                tabFrames: [
                    panelB: CGRect(x: 50, y: 0, width: 100, height: 30),
                    panelA: CGRect(x: 0, y: 0, width: 100, height: 30),
                ],
                closeFrames: [:]
            )
        )

        #expect(tester.tab(at: CGPoint(x: 75, y: 15)) == panelA)
        #expect(tester.tab(at: CGPoint(x: 140, y: 15)) == panelB)
    }

    @Test func closeHitOnlyUsesTheActuallyHoveredTab() {
        let panelA = UUID()
        let panelB = UUID()
        let pointInA = CGPoint(x: 12, y: 15)
        let tester = CanvasTabHitTester(
            tabOrder: [panelA, panelB],
            hitRegions: CanvasTabHitRegions(
                tabFrames: [
                    panelA: CGRect(x: 0, y: 0, width: 100, height: 30),
                    panelB: CGRect(x: 100, y: 0, width: 100, height: 30),
                ],
                closeFrames: [
                    panelA: CGRect(x: 0, y: 0, width: 24, height: 30),
                    panelB: CGRect(x: 100, y: 0, width: 24, height: 30),
                ]
            )
        )

        #expect(tester.closeTab(at: pointInA, hoveredTabId: nil) == nil)
        #expect(tester.closeTab(at: pointInA, hoveredTabId: panelB) == nil)
        #expect(tester.closeTab(at: pointInA, hoveredTabId: panelA) == panelA)
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
        mountFactory: ((UUID) -> TestMount)? = nil,
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
                descriptor(id: panelA, title: "A", focused: true, mountFactory: mountFactory),
                descriptor(id: panelB, title: "B", focused: false, mountFactory: mountFactory),
            ],
            focusedPanelId: panelA,
            isWorkspaceVisible: isWorkspaceVisible
        )
        root.layoutSubtreeIfNeeded()
        return root
    }

    private func descriptor(
        id: UUID,
        title: String,
        focused: Bool,
        showsInactiveOverlay: Bool? = nil,
        mountFactory: ((UUID) -> TestMount)? = nil
    ) -> CanvasPaneDescriptor {
        let showsInactiveOverlay = showsInactiveOverlay ?? !focused
        return CanvasPaneDescriptor(
            id: id,
            tab: CanvasTabChrome(id: id, title: title, iconSystemName: nil),
            isFocused: focused,
            closeActionLabel: "",
            makeMount: { _ in mountFactory?(id) ?? TestMount() },
            updateMount: { mount in
                (mount as? TestMount)?.recordPresentation(
                    isFocused: focused,
                    showsInactiveOverlay: showsInactiveOverlay
                )
            }
        )
    }

}
