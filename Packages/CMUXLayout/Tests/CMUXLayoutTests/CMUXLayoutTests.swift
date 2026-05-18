import XCTest
@testable import CMUXLayout
import AppKit
import SwiftUI

final class CMUXLayoutTests: XCTestCase {
    @MainActor
    private final class FakeTabBarHitRegionView: NSView {
        deinit {
            WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
            if window != nil {
                WorkspaceLayoutTabBarHitRegionRegistry.register(self)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil {
                WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
            }
        }
    }

    @MainActor
    private final class LayoutProbeView: NSView {
        private(set) var sizeChangeCount = 0
        private(set) var originChangeCount = 0

        override func setFrameSize(_ newSize: NSSize) {
            if frame.size != newSize {
                sizeChangeCount += 1
            }
            super.setFrameSize(newSize)
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            if frame.origin != newOrigin {
                originChangeCount += 1
            }
            super.setFrameOrigin(newOrigin)
        }
    }

    @MainActor
    private struct LayoutProbeRepresentable: NSViewRepresentable {
        let probeView: LayoutProbeView

        func makeNSView(context: Context) -> LayoutProbeView {
            probeView
        }

        func updateNSView(_ nsView: LayoutProbeView, context: Context) {}
    }

    @MainActor
    private final class DropZoneModel: ObservableObject {
        @Published var zone: DropZone?
    }

    @MainActor
    private struct PaneDropInteractionHarness: View {
        @ObservedObject var model: DropZoneModel
        let probeView: LayoutProbeView

        var body: some View {
            PaneDropInteractionContainer(activeDropZone: model.zone) {
                LayoutProbeRepresentable(probeView: probeView)
            } dropLayer: { _ in
                Color.clear
            }
        }
    }

    private final class SurfaceContextActionDelegateSpy: WorkspaceLayoutDelegate {
        var action: SurfaceContextAction?
        var tabId: SurfaceID?
        var paneId: PaneID?
        var moveDestinationId: String?

        func splitTabBar(_ controller: WorkspaceLayoutController, didRequestSurfaceContextAction action: SurfaceContextAction, for tab: CMUXLayout.SurfaceTab, inPane pane: PaneID) {
            self.action = action
            self.tabId = tab.id
            self.paneId = pane
        }

        func splitTabBar(_ controller: WorkspaceLayoutController, didRequestTabMoveToDestination destinationId: String, for tab: CMUXLayout.SurfaceTab, inPane pane: PaneID) {
            self.moveDestinationId = destinationId
            self.tabId = tab.id
            self.paneId = pane
        }
    }

    private final class NewTabRequestDelegateSpy: WorkspaceLayoutDelegate {
        var requestedKind: String?
        var requestedPaneId: PaneID?

        func splitTabBar(_ controller: WorkspaceLayoutController, didRequestNewTab kind: String, inPane pane: PaneID) {
            requestedKind = kind
            requestedPaneId = pane
        }
    }

    private final class CustomActionDelegateSpy: WorkspaceLayoutDelegate {
        var requestedIdentifier: String?
        var requestedPaneId: PaneID?

        func splitTabBar(_ controller: WorkspaceLayoutController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
            requestedIdentifier = identifier
            requestedPaneId = pane
        }
    }

    @MainActor
    func testControllerCreation() {
        let controller = WorkspaceLayoutController()
        XCTAssertNotNil(controller.focusedPaneId)
    }

    @MainActor
    func testTabCreation() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(title: "Test Surface", icon: "doc")
        XCTAssertNotNil(tabId)
    }

    @MainActor
    func testTabRetrieval() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(title: "Test Surface", icon: "doc")!
        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Test Surface")
        XCTAssertEqual(tab?.icon, "doc")
    }

    @MainActor
    func testTabUpdate() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(title: "Original", icon: "doc")!

        controller.updateTab(tabId, title: "Updated", isDirty: true)

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Updated")
        XCTAssertEqual(tab?.isDirty, true)
    }

    @MainActor
    func testTabClose() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(title: "Test Surface", icon: "doc")!

        let closed = controller.closeTab(tabId)

        XCTAssertTrue(closed)
        XCTAssertNil(controller.tab(tabId))
    }

    @MainActor
    func testCloseSelectedTabKeepsIndexStableWhenPossible() {
        do {
            let config = WorkspaceLayoutConfiguration(newTabPosition: .end)
            let controller = WorkspaceLayoutController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab1)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)

            _ = controller.closeTab(tab1)

            // Order is [0,1,2] and 1 was selected; after close we should select 2 (same index).
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)
            XCTAssertNotNil(controller.tab(tab0))
        }

        do {
            let config = WorkspaceLayoutConfiguration(newTabPosition: .end)
            let controller = WorkspaceLayoutController(configuration: config)

            let tab0 = controller.createTab(title: "0")!
            let tab1 = controller.createTab(title: "1")!
            let tab2 = controller.createTab(title: "2")!

            let pane = controller.focusedPaneId!

            controller.selectTab(tab2)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab2)

            _ = controller.closeTab(tab2)

            // Closing last should select previous.
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab1)
            XCTAssertNotNil(controller.tab(tab0))
        }
    }

    @MainActor
    func testConfiguration() {
        let config = WorkspaceLayoutConfiguration(
            allowSplits: false,
            allowCloseTabs: true
        )
        let controller = WorkspaceLayoutController(configuration: config)

        XCTAssertFalse(controller.configuration.allowSplits)
        XCTAssertTrue(controller.configuration.allowCloseTabs)
    }

    func testDefaultSplitButtonTooltips() {
        let defaults = WorkspaceLayoutConfiguration.SplitButtonTooltips.default
        XCTAssertEqual(defaults.newTerminal, "New Terminal")
        XCTAssertEqual(defaults.newBrowser, "New Browser")
        XCTAssertEqual(defaults.splitRight, "Split Right")
        XCTAssertEqual(defaults.splitDown, "Split Down")
    }

    func testDefaultSplitActionButtons() {
        XCTAssertEqual(
            WorkspaceLayoutConfiguration.SplitActionButton.defaults,
            [.newTerminal, .newBrowser, .splitRight, .splitDown]
        )
    }

    func testCustomSplitActionButtonRoundTrips() throws {
        let button = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "run-tests",
            systemImage: "checkmark.circle",
            tooltip: "Run tests",
            action: .custom("run-tests")
        )

        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutConfiguration.SplitActionButton.self, from: data)

        XCTAssertEqual(decoded, button)
    }

    func testCustomSplitActionButtonPreservesReservedActionName() throws {
        let button = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "custom-terminal",
            systemImage: "terminal",
            tooltip: "Custom terminal action",
            action: .custom("newTerminal")
        )

        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutConfiguration.SplitActionButton.self, from: data)

        XCTAssertEqual(decoded.action, .custom("newTerminal"))
        XCTAssertEqual(decoded, button)
    }

    func testSplitActionButtonDecodesLegacyBuiltInActionString() throws {
        let data = #"""
        {
          "id": "terminal",
          "icon": { "type": "systemImage", "name": "terminal" },
          "action": "newTerminal"
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorkspaceLayoutConfiguration.SplitActionButton.self, from: data)

        XCTAssertEqual(decoded.action, .newTerminal)
    }

    func testCustomSplitActionButtonSupportsEmojiIcon() throws {
        let button = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "agent",
            icon: .emoji("🤖", scale: 0.85),
            tooltip: "Start agent",
            action: .custom("agent")
        )

        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutConfiguration.SplitActionButton.self, from: data)

        XCTAssertEqual(decoded, button)
    }

    func testCustomSplitActionButtonSupportsImageDataIcon() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let button = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "image-agent",
            icon: .imageData(data),
            tooltip: "Start image agent",
            action: .custom("image-agent")
        )

        let encoded = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutConfiguration.SplitActionButton.self, from: encoded)

        XCTAssertEqual(decoded, button)
    }

    func testCurrentColorSVGImageDataRendersAsTemplate() throws {
        let templateSVG = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
              <path fill="currentColor" d="M4 4h16v16H4z"/>
            </svg>
            """.utf8
        )
        let colorSVG = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
              <path fill="#D97757" d="M4 4h16v16H4z"/>
            </svg>
            """.utf8
        )

        XCTAssertTrue(TabBarStyling.imageDataShouldRenderAsTemplate(templateSVG))
        XCTAssertFalse(TabBarStyling.imageDataShouldRenderAsTemplate(colorSVG))
    }

    func testCurrentColorSVGImageDataRendersAsTemplateWithInvalidUTF8Suffix() throws {
        var svg = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
              <path fill="currentColor" d="M4 4h16v16H4z"/>
            </svg>
            """.utf8
        )
        svg.append(0xE2)

        XCTAssertTrue(TabBarStyling.imageDataShouldRenderAsTemplate(svg))
    }

    @MainActor
    func testSplitActionButtonImageDataIsCached() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="))
        let first = try XCTUnwrap(TabBarStyling.splitActionButtonImage(from: png))
        let second = try XCTUnwrap(TabBarStyling.splitActionButtonImage(from: png))

        XCTAssertTrue(first === second)
    }

    func testMinimalModeDoesNotReserveHiddenSplitButtonStrip() {
        XCTAssertEqual(
            TabBarStyling.trailingTabContentInset(showSplitButtons: true, isMinimalMode: true),
            0,
            "Minimal mode should let the tab strip fill the full width until the hover-only split buttons are actually shown"
        )
        XCTAssertEqual(
            TabBarStyling.trailingTabContentInset(showSplitButtons: true, isMinimalMode: false),
            TabBarStyling.splitButtonsBackdropWidth(buttonCount: 4),
            "Standard mode should keep reserving space for the always-visible split buttons"
        )
        XCTAssertEqual(
            TabBarStyling.trailingTabContentInset(showSplitButtons: true, isMinimalMode: false, buttonCount: 2),
            TabBarStyling.splitButtonsBackdropWidth(buttonCount: 2),
            "Standard mode should reserve space for the configured split buttons only"
        )
        XCTAssertEqual(
            TabBarStyling.trailingTabContentInset(showSplitButtons: true, isMinimalMode: false, buttonCount: 0),
            0,
            "No strip should be reserved when the configured split button list is empty"
        )
        XCTAssertEqual(
            TabBarStyling.trailingTabContentInset(showSplitButtons: false, isMinimalMode: false),
            0,
            "No split-button strip should be reserved when split buttons are disabled"
        )
    }

    func testTabBarLayoutKeepsDefaultSplitButtonLaneWidthAsMinimum() {
        let compactMeasuredWidth =
            TabBarStyling.splitButtonsLeadingPadding
            + TabBarStyling.splitButtonsTrailingPadding
            + (4 * CGFloat(14))
            + (3 * TabBarStyling.splitButtonsSpacing)
        let layout = TabBarLayout(
            tabBarHeight: 28,
            splitButtonCount: 4,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: compactMeasuredWidth
        )

        XCTAssertEqual(
            layout.fullSplitButtonLaneWidth,
            TabBarStyling.splitButtonsBackdropWidth(buttonCount: 4)
        )
    }

    func testTabBarLayoutExpandsForMeasuredSplitButtonLaneWidth() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            splitButtonCount: 4,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 160
        )

        XCTAssertEqual(layout.fullSplitButtonLaneWidth, 160)
        XCTAssertEqual(layout.trailingTabContentInset, 160)
    }

    func testTabBarLayoutCapsSplitButtonLaneToQuarterOfAvailableWidth() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            availableWidth: 240,
            splitButtonCount: 12,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 400
        )

        XCTAssertEqual(layout.fullSplitButtonLaneWidth, 400)
        XCTAssertEqual(layout.maximumSplitButtonLaneWidth, 60)
        XCTAssertEqual(layout.visibleSplitButtonLaneWidth, 60)
        XCTAssertEqual(layout.trailingTabContentInset, 60)
        XCTAssertTrue(layout.splitButtonLaneOverflowsViewport)
    }

    func testTabBarLayoutKeepsMeasuredLaneWhenItFitsQuarterOfAvailableWidth() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            availableWidth: 800,
            splitButtonCount: 4,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 160
        )

        XCTAssertEqual(layout.fullSplitButtonLaneWidth, 160)
        XCTAssertEqual(layout.maximumSplitButtonLaneWidth, 200)
        XCTAssertEqual(layout.visibleSplitButtonLaneWidth, 160)
        XCTAssertEqual(layout.trailingTabContentInset, 160)
        XCTAssertFalse(layout.splitButtonLaneOverflowsViewport)
    }

    func testActionLaneSolidSurfaceCoversVisibleViewportWhenButtonsOverflow() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            availableWidth: 240,
            splitButtonCount: 12,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 400
        )
        let effect = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect(
            solidWidth: 23.875,
            solidSurfaceWidthAdjustment: -53,
            contentOcclusionFraction: 0.6875
        )
        let geometry = TabBarActionLaneGeometry(
            layout: layout,
            effect: effect,
            masksTabContent: true
        )

        XCTAssertEqual(layout.visibleSplitButtonLaneWidth, 60, accuracy: 0.0001)
        XCTAssertEqual(geometry.backgroundSolidWidth, 60, accuracy: 0.0001)
        XCTAssertEqual(geometry.contentOcclusionWidth, 60, accuracy: 0.0001)
    }

    func testActionLaneSolidSurfaceAllowsTrimWhenButtonsDoNotOverflow() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            availableWidth: 800,
            splitButtonCount: 4,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 160
        )
        let effect = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect(
            solidWidth: 23.875,
            solidSurfaceWidthAdjustment: -53,
            contentOcclusionFraction: 0.6875
        )
        let geometry = TabBarActionLaneGeometry(
            layout: layout,
            effect: effect,
            masksTabContent: true
        )

        XCTAssertEqual(layout.visibleSplitButtonLaneWidth, 160, accuracy: 0.0001)
        XCTAssertEqual(geometry.backgroundSolidWidth, 107, accuracy: 0.0001)
        XCTAssertEqual(geometry.contentOcclusionWidth, 110, accuracy: 0.0001)
    }

    func testSplitButtonBackdropSolidSurfaceCoversVisibleActionLane() {
        XCTAssertEqual(
            TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
                effectSolidWidth: 2,
                visibleLaneWidth: 90,
                solidSurfaceWidthAdjustment: 0
            ),
            90
        )
        XCTAssertEqual(
            TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
                effectSolidWidth: 96,
                visibleLaneWidth: 72,
                solidSurfaceWidthAdjustment: 0
            ),
            96
        )
    }

    func testSplitButtonContentOcclusionFractionDoesNotChangeSolidSurface() {
        let occlusion = TabBarStyling.splitButtonContentOcclusionWidth(
            visibleLaneWidth: 200,
            contentOcclusionFraction: 0.25
        )

        XCTAssertEqual(occlusion, 50)
        XCTAssertEqual(
            TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
                effectSolidWidth: 2,
                visibleLaneWidth: 200,
                solidSurfaceWidthAdjustment: 0
            ),
            200
        )
    }

    func testSplitButtonBackdropSolidSurfaceWidthCanBeAdjusted() {
        XCTAssertEqual(
            TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
                effectSolidWidth: 2,
                visibleLaneWidth: 90,
                solidSurfaceWidthAdjustment: 12
            ),
            102
        )
        XCTAssertEqual(
            TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
                effectSolidWidth: 2,
                visibleLaneWidth: 90,
                solidSurfaceWidthAdjustment: -12
            ),
            78
        )
    }

    func testSplitButtonScrollAffordancesTrackHiddenButtons() {
        var affordances = TabBarStyling.splitButtonScrollAffordances(
            scrollOffset: 0,
            contentWidth: 320,
            viewportWidth: 60
        )
        XCTAssertFalse(affordances.left)
        XCTAssertTrue(affordances.right)

        affordances = TabBarStyling.splitButtonScrollAffordances(
            scrollOffset: 120,
            contentWidth: 320,
            viewportWidth: 60
        )
        XCTAssertTrue(affordances.left)
        XCTAssertTrue(affordances.right)

        affordances = TabBarStyling.splitButtonScrollAffordances(
            scrollOffset: 260,
            contentWidth: 320,
            viewportWidth: 60
        )
        XCTAssertTrue(affordances.left)
        XCTAssertFalse(affordances.right)

        affordances = TabBarStyling.splitButtonScrollAffordances(
            scrollOffset: 0,
            contentWidth: 60,
            viewportWidth: 60
        )
        XCTAssertFalse(affordances.left)
        XCTAssertFalse(affordances.right)
    }

    func testTabBarLayoutDoesNotHardClipSelectedChromeAtSplitButtonLane() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            splitButtonCount: 4,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 160
        )
        let indicatorFrame = layout.selectedIndicatorFrame(
            selectedTabFrame: CGRect(x: 0, y: 0, width: 240, height: 28),
            totalWidth: 240
        )
        XCTAssertNotNil(indicatorFrame)
        XCTAssertEqual(
            indicatorFrame?.maxX ?? 0,
            239,
            accuracy: 0.001
        )
    }

    func testTabBarLayoutIgnoresMeasuredSplitButtonLaneWidthWithoutButtons() {
        let layout = TabBarLayout(
            tabBarHeight: 28,
            splitButtonCount: 0,
            splitButtonLaneVisible: false,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: 160
        )

        XCTAssertEqual(layout.fullSplitButtonLaneWidth, 0)
        XCTAssertEqual(layout.trailingTabContentInset, 0)
    }

    func testTabBarKeepsNonOverflowingTabsLeadingAligned() {
        let tabId = UUID()

        XCTAssertEqual(
            TabBarStyling.preferredScrollTarget(
                selectedTabId: tabId,
                contentWidth: 132,
                containerWidth: 349
            ),
            .leading,
            "When the tab strip fits in the pane, it should stay leading-aligned instead of creating a dead leading clip-view band"
        )

        XCTAssertEqual(
            TabBarStyling.preferredScrollTarget(
                selectedTabId: tabId,
                contentWidth: 420,
                containerWidth: 349
            ),
            .selectedTab(tabId),
            "Overflowing tab strips should still auto-scroll the selected tab into view"
        )
    }

    func testTabBarForcesLeadingResetWhenNonOverflowingStripStaysScrolled() {
        XCTAssertTrue(
            TabBarStyling.shouldForceResetToLeading(
                scrollOffset: 28,
                contentWidth: 180,
                containerWidth: 349
            ),
            "A non-overflowing tab strip with a stale horizontal offset should be snapped back to x=0"
        )

        XCTAssertTrue(
            TabBarStyling.shouldForceResetToLeading(
                scrollOffset: -30,
                contentWidth: 180,
                containerWidth: 349
            ),
            "The leading reset must correct both left and right stale offsets"
        )

        XCTAssertFalse(
            TabBarStyling.shouldForceResetToLeading(
                scrollOffset: 0.2,
                contentWidth: 180,
                containerWidth: 349
            ),
            "Tiny floating-point drift should not trigger redundant clip-view resets"
        )

        XCTAssertFalse(
            TabBarStyling.shouldForceResetToLeading(
                scrollOffset: 28,
                contentWidth: 420,
                containerWidth: 349
            ),
            "Overflowing tab strips are allowed to stay horizontally scrolled"
        )
    }

    @MainActor
    func testTabBarHitRegionRegistryTracksVisibleWindowPoint() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let tabBar = FakeTabBarHitRegionView(frame: NSRect(x: 20, y: 132, width: 180, height: 30))
        contentView.addSubview(tabBar)

        let hitPoint = tabBar.convert(NSPoint(x: 24, y: 12), to: nil)
        XCTAssertTrue(
            WorkspaceLayoutTabBarHitRegionRegistry.containsWindowPoint(hitPoint, in: window),
            "The registry should expose visible tab-bar hit regions in window coordinates"
        )

        let missPoint = tabBar.convert(NSPoint(x: 24, y: -18), to: nil)
        XCTAssertFalse(
            WorkspaceLayoutTabBarHitRegionRegistry.containsWindowPoint(missPoint, in: window),
            "The registry should ignore points outside the registered tab-bar region"
        )
    }

    @MainActor
    func testTabBarHitRegionRegistryIgnoresViewsHiddenByAncestors() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)

        let tabBar = FakeTabBarHitRegionView(frame: NSRect(x: 32, y: contentView.bounds.maxY + 6, width: 180, height: 30))
        container.addSubview(tabBar)

        let hitPoint = tabBar.convert(NSPoint(x: 20, y: 14), to: nil)
        XCTAssertTrue(
            WorkspaceLayoutTabBarHitRegionRegistry.containsWindowPoint(hitPoint, in: window),
            "The registry should use the actual registered tab-bar frame even when it extends outside its immediate container bounds"
        )

        container.isHidden = true
        XCTAssertFalse(
            WorkspaceLayoutTabBarHitRegionRegistry.containsWindowPoint(hitPoint, in: window),
            "Ancestor-hidden tab-bar regions must not keep stealing portal hit testing"
        )
    }

    @MainActor
    func testConfigurationAcceptsCustomSplitButtonTooltips() {
        let customTooltips = WorkspaceLayoutConfiguration.SplitButtonTooltips(
            newTerminal: "Terminal (⌘T)",
            newBrowser: "Browser (⌘⇧L)",
            splitRight: "Split Right (⌘D)",
            splitDown: "Split Down (⌘⇧D)"
        )
        let config = WorkspaceLayoutConfiguration(
            appearance: .init(
                splitButtonTooltips: customTooltips
            )
        )
        let controller = WorkspaceLayoutController(configuration: config)

        XCTAssertEqual(controller.configuration.appearance.splitButtonTooltips, customTooltips)
    }

    @MainActor
    func testConfigurationAcceptsCustomSplitActionButtons() {
        let buttons: [WorkspaceLayoutConfiguration.SplitActionButton] = [
            .newTerminal,
            .init(
                id: "run-tests",
                systemImage: "checkmark.circle",
                tooltip: "Run tests",
                action: .custom("run-tests")
            ),
        ]
        let config = WorkspaceLayoutConfiguration(
            appearance: .init(
                splitButtons: buttons
            )
        )
        let controller = WorkspaceLayoutController(configuration: config)

        XCTAssertEqual(controller.configuration.appearance.splitButtons, buttons)
    }

    func testAppearanceKeepsFirstSplitActionButtonForDuplicateIds() {
        let firstRunTests = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "run-tests",
            systemImage: "checkmark.circle",
            tooltip: "Run tests",
            action: .custom("run-tests")
        )
        let duplicateRunTests = WorkspaceLayoutConfiguration.SplitActionButton(
            id: "run-tests",
            systemImage: "xmark.circle",
            tooltip: "Duplicate",
            action: .custom("duplicate")
        )
        var appearance = WorkspaceLayoutConfiguration.Appearance(
            splitButtons: [.newTerminal, .newTerminal, firstRunTests, duplicateRunTests]
        )

        XCTAssertEqual(appearance.splitButtons, [.newTerminal, firstRunTests])

        appearance.splitButtons = [duplicateRunTests, firstRunTests, .splitRight]

        XCTAssertEqual(appearance.splitButtons, [duplicateRunTests, .splitRight])
    }

    @MainActor
    func testControllerRequestsCustomAction() {
        let controller = WorkspaceLayoutController()
        let delegate = CustomActionDelegateSpy()
        controller.delegate = delegate
        let paneId = controller.focusedPaneId!

        controller.requestCustomAction("run-tests", inPane: paneId)

        XCTAssertEqual(delegate.requestedIdentifier, "run-tests")
        XCTAssertEqual(delegate.requestedPaneId, paneId)
    }

    func testChromeBackgroundHexOverrideParsesForPaneBackground() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FDF6E3")
        )
        let color = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 253)
        XCTAssertEqual(Int(round(green * 255)), 246)
        XCTAssertEqual(Int(round(blue * 255)), 227)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testPaneBackgroundHexOverrideCanDifferFromChromeBackground() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#FDF6E3",
                paneBackgroundHex: "#11223380"
            )
        )
        let paneColor = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let barColor = NSColor(TabBarColors.barBackground(for: appearance)).usingColorSpace(.sRGB)!

        var paneRed: CGFloat = 0
        var paneGreen: CGFloat = 0
        var paneBlue: CGFloat = 0
        var paneAlpha: CGFloat = 0
        paneColor.getRed(&paneRed, green: &paneGreen, blue: &paneBlue, alpha: &paneAlpha)

        var barRed: CGFloat = 0
        var barGreen: CGFloat = 0
        var barBlue: CGFloat = 0
        var barAlpha: CGFloat = 0
        barColor.getRed(&barRed, green: &barGreen, blue: &barBlue, alpha: &barAlpha)

        XCTAssertEqual(Int(round(paneRed * 255)), 17)
        XCTAssertEqual(Int(round(paneGreen * 255)), 34)
        XCTAssertEqual(Int(round(paneBlue * 255)), 51)
        XCTAssertEqual(Int(round(paneAlpha * 255)), 128)
        XCTAssertEqual(Int(round(barRed * 255)), 253)
        XCTAssertEqual(Int(round(barGreen * 255)), 246)
        XCTAssertEqual(Int(round(barBlue * 255)), 227)
        XCTAssertEqual(Int(round(barAlpha * 255)), 255)
    }

    func testTabBarAndSplitButtonBackdropSurfacesCanBeExplicit() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#010203",
                tabBarBackgroundHex: "#11223380",
                splitButtonBackdropHex: "#44556699"
            )
        )
        let barColor = TabBarColors.nsColorBarBackground(for: appearance).usingColorSpace(.sRGB)!
        let backdropColor = TabBarColors.nsColorSplitButtonBackdropSurface(for: appearance).usingColorSpace(.sRGB)!

        var barRed: CGFloat = 0
        var barGreen: CGFloat = 0
        var barBlue: CGFloat = 0
        var barAlpha: CGFloat = 0
        barColor.getRed(&barRed, green: &barGreen, blue: &barBlue, alpha: &barAlpha)

        var backdropRed: CGFloat = 0
        var backdropGreen: CGFloat = 0
        var backdropBlue: CGFloat = 0
        var backdropAlpha: CGFloat = 0
        backdropColor.getRed(
            &backdropRed,
            green: &backdropGreen,
            blue: &backdropBlue,
            alpha: &backdropAlpha
        )

        XCTAssertEqual(Int(round(barRed * 255)), 17)
        XCTAssertEqual(Int(round(barGreen * 255)), 34)
        XCTAssertEqual(Int(round(barBlue * 255)), 51)
        XCTAssertEqual(Int(round(barAlpha * 255)), 128)
        XCTAssertEqual(Int(round(backdropRed * 255)), 68)
        XCTAssertEqual(Int(round(backdropGreen * 255)), 85)
        XCTAssertEqual(Int(round(backdropBlue * 255)), 102)
        XCTAssertEqual(Int(round(backdropAlpha * 255)), 153)
    }

    func testSplitButtonBackdropPrecomposesTranslucentPaneBackground() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#11223380",
                paneBackgroundHex: "#00000000"
            )
        )
        let color = TabBarColors.nsColorSplitButtonBackdrop(for: appearance).usingColorSpace(.sRGB)!
        let expected = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        var expectedRed: CGFloat = 0
        var expectedGreen: CGFloat = 0
        var expectedBlue: CGFloat = 0
        var expectedAlpha: CGFloat = 0
        expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha)

        XCTAssertEqual(Int(round(red * 255)), Int(round(expectedRed * 255)))
        XCTAssertEqual(Int(round(green * 255)), Int(round(expectedGreen * 255)))
        XCTAssertEqual(Int(round(blue * 255)), Int(round(expectedBlue * 255)))
        XCTAssertEqual(Int(round(alpha * 255)), 255)
        XCTAssertTrue(TabBarColors.shouldPaintSplitButtonBackdrop(for: appearance))
    }

    func testSplitButtonBackdropPaintsForOpaqueChromeBackground() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#112233")
        )

        XCTAssertTrue(TabBarColors.shouldPaintSplitButtonBackdrop(for: appearance))
    }

    func testSplitButtonBackdropEffectTracksSolidWidthSeparately() {
        let effect = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect(
            fadeWidth: 80,
            contentFadeWidth: 42,
            solidWidth: 32,
            solidSurfaceWidthAdjustment: 7,
            fadeRampStartFraction: 0.58,
            contentOcclusionFraction: 0.25
        )

        XCTAssertEqual(effect.fadeWidth, 80)
        XCTAssertEqual(effect.contentFadeWidth, 42)
        XCTAssertEqual(effect.solidWidth, 32)
        XCTAssertEqual(effect.solidSurfaceWidthAdjustment, 7)
        XCTAssertNil(effect.separatorFadeWidth)
        XCTAssertEqual(effect.fadeRampStartFraction, 0.58)
        XCTAssertEqual(effect.contentOcclusionFraction, 0.25)

        let clamped = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect(
            solidSurfaceWidthAdjustment: .infinity,
            separatorFadeWidth: -4,
            fadeRampStartFraction: 1.4,
            contentOcclusionFraction: 2.2
        )
        XCTAssertEqual(clamped.solidSurfaceWidthAdjustment, 0)
        XCTAssertEqual(clamped.separatorFadeWidth, 0)
        XCTAssertEqual(clamped.fadeRampStartFraction, 0.95)
        XCTAssertEqual(clamped.contentOcclusionFraction, 1.0)
    }

    func testChromeBorderHexOverrideParsesForSeparatorColor() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822", borderHex: "#112233")
        )
        let color = TabBarColors.nsColorSeparator(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 17)
        XCTAssertEqual(Int(round(green * 255)), 34)
        XCTAssertEqual(Int(round(blue * 255)), 51)
        XCTAssertEqual(Int(round(alpha * 255)), 255)
    }

    func testInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#ZZZZZZ")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testPartiallyInvalidChromeBackgroundHexFallsBackToPaneDefaultColor() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#FF000G")
        )
        let resolved = TabBarColors.nsColorPaneBackground(for: appearance).usingColorSpace(.sRGB)!
        let fallback = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        fallback.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        XCTAssertEqual(rr, fr, accuracy: 0.0001)
        XCTAssertEqual(rg, fg, accuracy: 0.0001)
        XCTAssertEqual(rb, fb, accuracy: 0.0001)
        XCTAssertEqual(ra, fa, accuracy: 0.0001)
    }

    func testInactiveTextUsesLightForegroundOnDarkCustomChromeBackground() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )
        let color = TabBarColors.nsColorInactiveText(for: appearance).usingColorSpace(.sRGB)!

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertGreaterThan(red, 0.5)
        XCTAssertGreaterThan(green, 0.5)
        XCTAssertGreaterThan(blue, 0.5)
        XCTAssertGreaterThan(alpha, 0.6)
    }

    func testSharedBackdropUsesSemanticBackgroundForTextAndHover() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#272822",
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000"
            ),
            usesSharedBackdrop: true
        )
        let text = TabBarColors.nsColorInactiveText(for: appearance).usingColorSpace(.sRGB)!
        let hover = NSColor(TabBarColors.hoveredTabBackground(for: appearance)).usingColorSpace(.sRGB)!

        var textRed: CGFloat = 0
        var textGreen: CGFloat = 0
        var textBlue: CGFloat = 0
        var textAlpha: CGFloat = 0
        text.getRed(&textRed, green: &textGreen, blue: &textBlue, alpha: &textAlpha)

        var hoverRed: CGFloat = 0
        var hoverGreen: CGFloat = 0
        var hoverBlue: CGFloat = 0
        var hoverAlpha: CGFloat = 0
        hover.getRed(&hoverRed, green: &hoverGreen, blue: &hoverBlue, alpha: &hoverAlpha)

        XCTAssertGreaterThan(textRed, 0.5)
        XCTAssertGreaterThan(textGreen, 0.5)
        XCTAssertGreaterThan(textBlue, 0.5)
        XCTAssertGreaterThan(textAlpha, 0.6)
        XCTAssertGreaterThan(hoverRed, 0.9)
        XCTAssertGreaterThan(hoverGreen, 0.9)
        XCTAssertGreaterThan(hoverBlue, 0.9)
        XCTAssertGreaterThan(hoverAlpha, 0.04)
        XCTAssertLessThan(hoverAlpha, 0.12)
    }

    func testSplitActionPressedStateUsesHigherContrast() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )

        let idleIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false).usingColorSpace(.sRGB)!
        let pressedIcon = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: true).usingColorSpace(.sRGB)!

        var idleAlpha: CGFloat = 0
        idleIcon.getRed(nil, green: nil, blue: nil, alpha: &idleAlpha)
        var pressedAlpha: CGFloat = 0
        pressedIcon.getRed(nil, green: nil, blue: nil, alpha: &pressedAlpha)

        XCTAssertGreaterThan(pressedAlpha, idleAlpha)
    }

    @MainActor
    func testMoveTabNoopAfterItself() {
        let t0 = SurfaceItem(title: "0")
        let t1 = SurfaceItem(title: "1")
        let pane = PaneState(tabs: [t0, t1], selectedTabId: t1.id)

        // Dragging the last tab to the right corresponds to moving it to `tabs.count`,
        // which should be treated as a no-op.
        pane.moveTab(from: 1, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t0.id, t1.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)

        // Still allow real moves.
        pane.moveTab(from: 0, to: 2)
        XCTAssertEqual(pane.tabs.map(\.id), [t1.id, t0.id])
        XCTAssertEqual(pane.selectedTabId, t1.id)
    }

    @MainActor
    func testPinnedTabInsertionsStayAheadOfUnpinnedTabs() {
        let unpinnedA = SurfaceItem(title: "A", isPinned: false)
        let unpinnedB = SurfaceItem(title: "B", isPinned: false)
        let pinned = SurfaceItem(title: "Pinned", isPinned: true)
        let pane = PaneState(tabs: [unpinnedA, unpinnedB], selectedTabId: unpinnedA.id)

        pane.insertTab(pinned, at: 2)

        XCTAssertEqual(pane.tabs.map(\.isPinned), [true, false, false])
        XCTAssertEqual(pane.tabs.first?.id, pinned.id)
    }

    @MainActor
    func testMovingUnpinnedTabCannotCrossPinnedBoundary() {
        let pinnedA = SurfaceItem(title: "Pinned A", isPinned: true)
        let pinnedB = SurfaceItem(title: "Pinned B", isPinned: true)
        let unpinnedA = SurfaceItem(title: "A", isPinned: false)
        let unpinnedB = SurfaceItem(title: "B", isPinned: false)
        let pane = PaneState(
            tabs: [pinnedA, pinnedB, unpinnedA, unpinnedB],
            selectedTabId: unpinnedB.id
        )

        // Attempt to move an unpinned tab ahead of pinned tabs; move should clamp to
        // the first unpinned position.
        pane.moveTab(from: 3, to: 0)

        XCTAssertEqual(pane.tabs.map(\.id), [pinnedA.id, pinnedB.id, unpinnedB.id, unpinnedA.id])
        XCTAssertEqual(pane.tabs.prefix(2).allSatisfy(\.isPinned), true)
        XCTAssertEqual(pane.tabs.suffix(2).allSatisfy { !$0.isPinned }, true)
    }

    @MainActor
    func testCreateTabStoresKindAndPinnedState() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(
            title: "Browser",
            icon: "globe",
            kind: "browser",
            isPinned: true
        )!

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.kind, "browser")
        XCTAssertEqual(tab?.isPinned, true)
    }

    @MainActor
    func testCreateAndUpdateTabCustomTitleFlag() {
        let controller = WorkspaceLayoutController()
        let tabId = controller.createTab(
            title: "Infra",
            hasCustomTitle: true
        )!

        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, true)

        controller.updateTab(tabId, hasCustomTitle: false)
        XCTAssertEqual(controller.tab(tabId)?.hasCustomTitle, false)
    }

    @MainActor
    func testSplitPaneWithOptionalTabPreservesCustomTitleFlag() {
        let controller = WorkspaceLayoutController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = CMUXLayout.SurfaceTab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(sourcePaneId, orientation: .horizontal, withTab: customTab) else {
            return XCTFail("Expected splitPane to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testSplitPaneWithInsertSidePreservesCustomTitleFlag() {
        let controller = WorkspaceLayoutController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = controller.focusedPaneId!
        let customTab = CMUXLayout.SurfaceTab(title: "Custom", hasCustomTitle: true)

        guard let newPaneId = controller.splitPane(
            sourcePaneId,
            orientation: .vertical,
            withTab: customTab,
            insertFirst: true
        ) else {
            return XCTFail("Expected splitPane(insertFirst:) to return new pane")
        }
        let inserted = controller.tabs(inPane: newPaneId).first(where: { $0.id == customTab.id })
        XCTAssertEqual(inserted?.hasCustomTitle, true)
    }

    @MainActor
    func testTogglePaneZoomTracksState() {
        let controller = WorkspaceLayoutController()
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        // Single-pane layouts cannot be zoomed.
        XCTAssertFalse(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)

        guard controller.splitPane(originalPane, orientation: .horizontal) != nil else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertEqual(controller.zoomedPaneId, originalPane)
        XCTAssertTrue(controller.isSplitZoomed)

        XCTAssertTrue(controller.togglePaneZoom(inPane: originalPane))
        XCTAssertNil(controller.zoomedPaneId)
        XCTAssertFalse(controller.isSplitZoomed)
    }

    @MainActor
    func testSplitClearsExistingPaneZoom() {
        let controller = WorkspaceLayoutController()
        guard let originalPane = controller.focusedPaneId else {
            return XCTFail("Expected focused pane")
        }

        guard let secondPane = controller.splitPane(originalPane, orientation: .horizontal) else {
            return XCTFail("Expected splitPane to create a new pane")
        }

        XCTAssertTrue(controller.togglePaneZoom(inPane: secondPane))
        XCTAssertEqual(controller.zoomedPaneId, secondPane)

        _ = controller.splitPane(secondPane, orientation: .vertical)
        XCTAssertNil(controller.zoomedPaneId, "Splitting should reset zoom state")
    }

    @MainActor
    func testRequestSurfaceContextActionForwardsToDelegate() {
        let controller = WorkspaceLayoutController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "browser")!
        let spy = SurfaceContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestSurfaceContextAction(.reload, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .reload)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testRequestSurfaceContextActionForwardsMarkAsReadToDelegate() {
        let controller = WorkspaceLayoutController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "terminal")!
        let spy = SurfaceContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestSurfaceContextAction(.markAsRead, for: tabId, inPane: pane)

        XCTAssertEqual(spy.action, .markAsRead)
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testRequestTabMoveDestinationForwardsToDelegate() {
        let controller = WorkspaceLayoutController()
        let pane = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", kind: "terminal")!
        let spy = SurfaceContextActionDelegateSpy()
        controller.delegate = spy

        controller.requestTabMove(toDestination: "workspace:abc", for: tabId, inPane: pane)

        XCTAssertEqual(spy.moveDestinationId, "workspace:abc")
        XCTAssertEqual(spy.tabId, tabId)
        XCTAssertEqual(spy.paneId, pane)
    }

    @MainActor
    func testTabContextMenuBuilderCreatesAppKitMoveSubmenu() throws {
        let target = TabContextMenuActionTarget()
        var selectedAction: SurfaceContextAction?
        var selectedDestinationId: String?
        target.onContextAction = { selectedAction = $0 }
        target.onMoveDestination = { selectedDestinationId = $0 }
        let state = TabContextMenuState(
            isPinned: false,
            isUnread: false,
            isBrowser: false,
            isTerminal: true,
            hasCustomTitle: false,
            canCloseToLeft: true,
            canCloseToRight: true,
            canCloseOthers: true,
            canMoveToNewWorkspace: true,
            canMoveToLeftPane: false,
            canMoveToRightPane: true,
            isZoomed: false,
            hasSplits: true,
            moveDestinations: [
                SurfaceMoveDestination(id: "workspace:abc", title: "Workspace A", isEnabled: false)
            ],
            shortcuts: [:]
        )
        let snapshot = TabContextMenuSnapshot(tabId: UUID(), state: state)

        let menu = TabContextMenuBuilder.makeMenu(snapshot: snapshot, target: target)
        let moveItem = menu.items.first { $0.title == "Move Surface" }

        XCTAssertNotNil(moveItem)
        XCTAssertTrue(moveItem?.isEnabled ?? false)
        XCTAssertEqual(moveItem?.submenu?.items.map(\.title), ["Move Surface to New Workspace", "Workspace A"])
        XCTAssertEqual(moveItem?.submenu?.items.map(\.isEnabled), [true, false])

        let newWorkspaceItem = try XCTUnwrap(moveItem?.submenu?.items.first)
        target.performContextAction(newWorkspaceItem)
        XCTAssertEqual(selectedAction, .moveToNewWorkspace)

        let workspaceItem = try XCTUnwrap(moveItem?.submenu?.items.dropFirst().first)
        target.performMoveDestination(workspaceItem)
        XCTAssertEqual(selectedDestinationId, "workspace:abc")
    }

    @MainActor
    func testDoubleClickingEmptyTrailingTabBarSpaceRequestsNewTerminalTab() {
        let appearance = WorkspaceLayoutConfiguration.Appearance()
        let configuration = WorkspaceLayoutConfiguration(appearance: appearance)
        let controller = WorkspaceLayoutController(configuration: configuration)
        let pane = controller.internalController.rootNode.allPanes.first!
        let spy = NewTabRequestDelegateSpy()
        controller.delegate = spy

        let hostingView = NSHostingView(
            rootView: TabBarView(pane: pane, isFocused: true, showSplitButtons: true)
                .environment(controller)
                .environment(controller.internalController)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let clickPoint = NSPoint(x: hostingView.bounds.maxX - 12, y: hostingView.bounds.midY)
        let pointInWindow = hostingView.convert(clickPoint, to: nil)
        guard let hitView = waitForDescendant(
            ofType: TabBarDragZoneView.DragNSView.self,
            in: contentView,
            containingWindowPoint: pointInWindow,
            where: { $0.onDoubleClick != nil }
        ) else {
            XCTFail("Expected trailing tab bar drag zone")
            return
        }
        XCTAssertEqual(hitView.onDoubleClick?(), true)

        XCTAssertEqual(spy.requestedKind, "terminal")
        XCTAssertEqual(spy.requestedPaneId, pane.id)
    }

    @MainActor
    func testEmptyTrailingTabBarSpaceDoesNotRequestNewTerminalWhenButtonHidden() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(splitButtons: [])
        let configuration = WorkspaceLayoutConfiguration(appearance: appearance)
        let controller = WorkspaceLayoutController(configuration: configuration)
        let pane = controller.internalController.rootNode.allPanes.first!
        let spy = NewTabRequestDelegateSpy()
        controller.delegate = spy

        let hostingView = NSHostingView(
            rootView: TabBarView(pane: pane, isFocused: true, showSplitButtons: true)
                .environment(controller)
                .environment(controller.internalController)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let clickPoint = NSPoint(x: hostingView.bounds.maxX - 12, y: hostingView.bounds.midY)
        let pointInWindow = hostingView.convert(clickPoint, to: nil)
        guard let hitView = waitForDescendant(
            ofType: TabBarDragZoneView.DragNSView.self,
            in: contentView,
            containingWindowPoint: pointInWindow,
            where: { $0.onDoubleClick != nil }
        ) else {
            XCTFail("Expected trailing tab bar drag zone")
            return
        }
        XCTAssertEqual(hitView.onDoubleClick?(), false)

        XCTAssertNil(spy.requestedKind)
        XCTAssertNil(spy.requestedPaneId)
    }

    func testIconSaturationKeepsRasterFaviconInColorWhenInactive() {
        XCTAssertEqual(
            SurfaceItemStyling.iconSaturation(hasRasterIcon: true, tabSaturation: 0.0),
            1.0
        )
    }

    func testIconSaturationStillDesaturatesSymbolIconsWhenInactive() {
        XCTAssertEqual(
            SurfaceItemStyling.iconSaturation(hasRasterIcon: false, tabSaturation: 0.0),
            0.0
        )
    }

    func testResolvedFaviconImageUsesIncomingDataWhenDecodable() {
        let existing = NSImage(size: NSSize(width: 12, height: 12))
        let incoming = NSImage(size: NSSize(width: 16, height: 16))
        incoming.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        incoming.unlockFocus()
        let data = incoming.tiffRepresentation

        let resolved = SurfaceItemStyling.resolvedFaviconImage(existing: existing, incomingData: data)
        XCTAssertNotNil(resolved)
        XCTAssertFalse(resolved === existing)
    }

    func testResolvedFaviconImageKeepsExistingImageWhenIncomingDataIsInvalid() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let invalidData = Data([0x00, 0x11, 0x22, 0x33])

        let resolved = SurfaceItemStyling.resolvedFaviconImage(existing: existing, incomingData: invalidData)
        XCTAssertTrue(resolved === existing)
    }

    func testResolvedFaviconImageClearsWhenIncomingDataIsNil() {
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        let resolved = SurfaceItemStyling.resolvedFaviconImage(existing: existing, incomingData: nil)
        XCTAssertNil(resolved)
    }

    func testTabControlShortcutHintPolicyMatchesConfiguredModifiers() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults)?.symbol,
                "⌃"
            )
            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults)?.symbol,
                "⌃"
            )
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control, .shift], defaults: defaults))
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command, .option], defaults: defaults))

            defaults.set(
                shortcutData(
                    key: "1",
                    command: true,
                    shift: false,
                    option: true,
                    control: false
                ),
                forKey: "shortcut.selectSurfaceByNumber"
            )

            let custom = TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults)
            XCTAssertEqual(custom?.symbol, "⌥⌘")
            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults)?.symbol,
                "⌥⌘"
            )
            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults)?.symbol,
                "⌥⌘"
            )
        }
    }

    func testTabControlShortcutHintPolicyCanDisableCommandAndControlHoldHintsIndependently() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(false, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults))
            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults)?.symbol,
                "⌃"
            )

            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.set(false, forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertEqual(
                TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults)?.symbol,
                "⌃"
            )
            XCTAssertNil(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults))
        }
    }

    func testTabControlShortcutHintPolicyDefaultsToShowingHoldHints() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.removeObject(forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.removeObject(forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.control], defaults: defaults)?.symbol, "⌃")
            XCTAssertEqual(TabControlShortcutHintPolicy.hintModifier(for: [.command], defaults: defaults)?.symbol, "⌃")
        }
    }

    func testTabControlShortcutHintsAreScopedToCurrentKeyWindow() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: 7,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: false,
                    eventWindowNumber: 42,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )
        }
    }

    func testTabControlShortcutHintsFallbackToKeyWindowWhenEventWindowMissing() {
        withShortcutHintDefaultsSuite { defaults in
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnCommandHoldKey)
            defaults.set(true, forKey: TabControlShortcutHintPolicy.showHintsOnControlHoldKey)

            XCTAssertTrue(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 42,
                    defaults: defaults
                )
            )

            XCTAssertFalse(
                TabControlShortcutHintPolicy.shouldShowHints(
                    for: [.control],
                    hostWindowNumber: 42,
                    hostWindowIsKey: true,
                    eventWindowNumber: nil,
                    keyWindowNumber: 7,
                    defaults: defaults
                )
            )
        }
    }

    @MainActor
    func testControllerMirrorsTabShortcutHintEligibilityToInternalController() {
        let controller = WorkspaceLayoutController()

        XCTAssertTrue(controller.tabShortcutHintsEnabled)
        XCTAssertTrue(controller.internalController.tabShortcutHintsEnabled)

        controller.tabShortcutHintsEnabled = false

        XCTAssertFalse(controller.tabShortcutHintsEnabled)
        XCTAssertFalse(controller.internalController.tabShortcutHintsEnabled)
    }

    func testLegacyFileDropsOnlyValidateCenterZone() {
        XCTAssertTrue(
            UnifiedPaneDropDelegate.acceptsFileDrop(
                zone: .center,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: true
            )
        )
        XCTAssertFalse(
            UnifiedPaneDropDelegate.acceptsFileDrop(
                zone: .left,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: true
            )
        )
        XCTAssertFalse(
            UnifiedPaneDropDelegate.acceptsFileDrop(
                zone: .center,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: false
            )
        )
        XCTAssertTrue(
            UnifiedPaneDropDelegate.acceptsFileDrop(
                zone: .right,
                hasExternalFileDropHandler: true,
                hasLegacyFileDropHandler: false
            )
        )
    }

    func testLegacyFileDropUpdatedRejectsEdgeZones() {
        XCTAssertEqual(
            UnifiedPaneDropDelegate.acceptedDropZone(
                .center,
                isFileDropOnly: true,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: true
            ),
            .center
        )
        XCTAssertNil(
            UnifiedPaneDropDelegate.acceptedDropZone(
                .left,
                isFileDropOnly: true,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: true
            )
        )
        XCTAssertEqual(
            UnifiedPaneDropDelegate.acceptedDropZone(
                .left,
                isFileDropOnly: true,
                hasExternalFileDropHandler: true,
                hasLegacyFileDropHandler: false
            ),
            .left
        )
        XCTAssertEqual(
            UnifiedPaneDropDelegate.acceptedDropZone(
                .left,
                isFileDropOnly: false,
                hasExternalFileDropHandler: false,
                hasLegacyFileDropHandler: false
            ),
            .left
        )
    }

    func testFileURLPasteboardReaderReturnsFileURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxlayout-file-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sample.txt")
        try "sample".write(to: fileURL, atomically: true, encoding: .utf8)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmuxlayout.file-drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        XCTAssertEqual(UnifiedPaneDropDelegate.fileURLs(from: pasteboard), [fileURL])
    }

    func testFileDropValidationRequiresReadablePasteboardURLs() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmuxlayout.file-drop.empty.\(UUID().uuidString)"))
        pasteboard.clearContents()

        XCTAssertFalse(UnifiedPaneDropDelegate.hasReadableFileURLs(from: pasteboard))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxlayout-file-drop-readable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sample.txt")
        try "sample".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        XCTAssertTrue(UnifiedPaneDropDelegate.hasReadableFileURLs(from: pasteboard))
    }

    func testFileOnlyDropsDoNotUseStaleLocalTabDragState() {
        XCTAssertFalse(
            UnifiedPaneDropDelegate.shouldUseLocalTabDrag(
                hasTabTransfer: false,
                hasFileURL: true,
                hasLocalTabDrag: true
            )
        )
        XCTAssertTrue(
            UnifiedPaneDropDelegate.shouldUseLocalTabDrag(
                hasTabTransfer: true,
                hasFileURL: false,
                hasLocalTabDrag: true
            )
        )
        XCTAssertFalse(
            UnifiedPaneDropDelegate.shouldUseLocalTabDrag(
                hasTabTransfer: true,
                hasFileURL: false,
                hasLocalTabDrag: false
            )
        )
    }

    func testSelectedTabNeverShowsHoverBackground() {
        XCTAssertFalse(
            SurfaceItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: true)
        )
        XCTAssertTrue(
            SurfaceItemStyling.shouldShowHoverBackground(isHovered: true, isSelected: false)
        )
        XCTAssertFalse(
            SurfaceItemStyling.shouldShowHoverBackground(isHovered: false, isSelected: false)
        )
    }

    func testActiveTabIndicatorHeightIsOneAndHalfPixels() {
        XCTAssertEqual(TabBarMetrics.activeIndicatorHeight, 1.5)
    }

    @MainActor
    func testActiveTabIndicatorLeavesTrailingPixelGap() {
        guard let width = renderedTabBarIndicatorWidth(isFocused: true) else {
            XCTFail("Expected rendered tab bar indicator width")
            return
        }

        XCTAssertEqual(width, TabBarMetrics.tabMinWidth - 1, accuracy: 0.5)
    }

    @MainActor
    func testSelectedTabLeftSeparatorDoesNotOverlapBottomSeparator() {
        guard let alphas = renderedSelectedTabLeftSeparatorAlphas() else {
            XCTFail("Expected rendered selected tab separator alphas")
            return
        }

        XCTAssertGreaterThan(alphas.top, 0.3)
        XCTAssertEqual(alphas.bottom, alphas.top, accuracy: 0.08)
    }

    @MainActor
    func testInactiveSelectedTabIndicatorUsesDesaturatedAccent() {
        guard let focusedSaturation = renderedTabBarIndicatorSaturation(isFocused: true),
              let unfocusedSaturation = renderedTabBarIndicatorSaturation(isFocused: false) else {
            XCTFail("Expected rendered tab bar colors")
            return
        }

        XCTAssertGreaterThan(focusedSaturation, 0.4)
        XCTAssertLessThan(unfocusedSaturation, 0.1)
    }

    @MainActor
    func testSplitButtonLaneDoesNotExposeSelectedTabIndicator() {
        guard let saturation = renderedSplitButtonLaneTopSaturation() else {
            XCTFail("Expected rendered split button lane colors")
            return
        }

        XCTAssertLessThan(saturation, 0.2)
    }

    @MainActor
    func testSplitButtonBackdropFadePaintsFullTabBarHeight() {
        guard let delta = renderedSplitButtonBackdropFadeVerticalColorDelta() else {
            XCTFail("Expected rendered split button backdrop fade colors")
            return
        }

        XCTAssertLessThan(delta, 0.08)
    }

    @MainActor
    func testSplitButtonBackdropSolidSurfaceCoversVisibleLane() {
        guard let brightness = renderedSplitButtonLaneSolidBackdropBrightness() else {
            XCTFail("Expected rendered split button lane backdrop color")
            return
        }

        XCTAssertGreaterThan(brightness, 0.5)
    }

    @MainActor
    func testSplitButtonBackdropDoesNotPaintSolidSurfaceAtTabContentFadeStart() {
        guard let brightness = renderedSplitButtonContentFadeStartBackdropBrightness() else {
            XCTFail("Expected rendered split button content fade backdrop color")
            return
        }

        XCTAssertLessThan(brightness, 0.1)
    }

    @MainActor
    func testSplitButtonBackdropOccludesTabChromeAtContentFadeStart() {
        guard let saturation = renderedSplitButtonContentFadeStartSaturation() else {
            XCTFail("Expected rendered split button content fade colors")
            return
        }

        XCTAssertLessThan(saturation, 0.2)
    }

    @MainActor
    func testSelectedTabIndicatorDoesNotBleedUnderSplitButtonBackdrop() {
        guard let brightnesses = renderedSelectedIndicatorBackdropBrightnesses() else {
            XCTFail("Expected rendered selected indicator backdrop colors")
            return
        }

        XCTAssertLessThan(brightnesses.leading, 0.08)
        XCTAssertLessThan(brightnesses.trailing, 0.08)
    }

    @MainActor
    func testSharedBackdropTransparentActionLaneDoesNotPaintSyntheticSurface() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#272822B8",
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000"
            ),
            usesSharedBackdrop: true
        )

        XCTAssertFalse(TabBarColors.shouldPaintSplitButtonBackdrop(for: appearance))
    }

    @MainActor
    func testSharedBackdropManySplitButtonsMaskTabContentWithoutSyntheticSurface() {
        guard let alpha = renderedSharedBackdropActionLaneSurfaceAlpha() else {
            XCTFail("Expected rendered shared backdrop action lane color")
            return
        }

        XCTAssertLessThan(alpha, 0.05)
    }

    @MainActor
    func testOverflowingSplitButtonsClipToActionLane() {
        guard let brightness = renderedEscapedSplitButtonBrightnessOutsideActionLane() else {
            XCTFail("Expected rendered split button overflow colors")
            return
        }

        XCTAssertLessThan(brightness, 0.30)
    }

    @MainActor
    func testSharedBackdropActionLaneBottomSeparatorCoversSolidAreaAndFadesOut() {
        guard let alphas = renderedSharedBackdropActionLaneBottomSeparatorAlphas() else {
            XCTFail("Expected rendered shared backdrop action lane separator colors")
            return
        }

        XCTAssertGreaterThan(alphas.solid, 0.25)
        XCTAssertLessThan(alphas.fadeStart, alphas.solid * 0.25)
        XCTAssertLessThan(alphas.beforeRamp, alphas.solid * 0.25)
        XCTAssertGreaterThan(alphas.afterRamp, alphas.solid * 0.25)
        XCTAssertGreaterThan(alphas.fadeEnd, alphas.solid * 0.55)
        XCTAssertEqual(alphas.fadeEnd, alphas.solidStart, accuracy: 0.15)
    }

    func testSharedBackdropActionLaneSeparatorMatchesBackdropGradientGeometry() {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let layout = TabBarLayout(
            tabBarHeight: size.height,
            availableWidth: size.width,
            splitButtonCount: buttonCount,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: TabBarStyling.splitButtonsBackdropWidth(buttonCount: buttonCount)
        )
        let snapshot = TabBarChromeSnapshot(
            appearance: sharedBackdropManyActionAppearance(
                tabBarHeight: size.height,
                buttonCount: buttonCount
            ),
            layout: layout,
            isFocused: true,
            shouldShowSplitButtons: true,
            fadeColorStyle: 0
        )

        XCTAssertEqual(snapshot.actionLaneSeparatorFadeWidth, snapshot.backdropFadeWidth, accuracy: 0.0001)
        XCTAssertEqual(snapshot.actionLaneSeparatorSolidWidth, snapshot.actionLaneWidth, accuracy: 0.0001)
        XCTAssertEqual(snapshot.backdropSolidWidth, snapshot.actionLaneWidth, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.actionLaneSeparatorFadeWidth + snapshot.actionLaneSeparatorSolidWidth,
            snapshot.backdropFadeWidth + snapshot.actionLaneWidth,
            accuracy: 0.0001
        )
    }

    func testSharedBackdropActionLaneSeparatorCanBeNarrowerThanContentFade() {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let layout = TabBarLayout(
            tabBarHeight: size.height,
            availableWidth: size.width,
            splitButtonCount: buttonCount,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: TabBarStyling.splitButtonsBackdropWidth(buttonCount: buttonCount)
        )
        let appearance = sharedBackdropManyActionAppearance(
            tabBarHeight: size.height,
            buttonCount: buttonCount,
            separatorFadeWidth: 12
        )
        let snapshot = TabBarChromeSnapshot(
            appearance: appearance,
            layout: layout,
            isFocused: true,
            shouldShowSplitButtons: true,
            fadeColorStyle: 0
        )

        XCTAssertEqual(snapshot.contentFadeWidth, 28.875, accuracy: 0.0001)
        XCTAssertEqual(snapshot.actionLaneSeparatorFadeWidth, 12, accuracy: 0.0001)
        XCTAssertLessThan(snapshot.actionLaneSeparatorFadeWidth, snapshot.contentFadeWidth)
    }

    func testActionLaneFallbackSeparatorClipsToSelectedSeparatorGap() {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let layout = TabBarLayout(
            tabBarHeight: size.height,
            availableWidth: size.width,
            splitButtonCount: buttonCount,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: TabBarStyling.splitButtonsBackdropWidth(buttonCount: buttonCount)
        )
        let snapshot = TabBarChromeSnapshot(
            appearance: sharedBackdropManyActionAppearance(
                tabBarHeight: size.height,
                buttonCount: buttonCount,
                separatorFadeWidth: 12
            ),
            layout: layout,
            isFocused: true,
            shouldShowSplitButtons: true,
            fadeColorStyle: 0
        )
        let geometry = snapshot.actionLaneGeometry
        let mask = geometry.fallbackSeparatorMaskFrame(
            totalWidth: size.width,
            height: size.height,
            selectedSeparatorGap: 300...340
        )

        XCTAssertEqual(mask?.minX ?? -1, 300, accuracy: 0.0001)
        XCTAssertEqual(mask?.maxX ?? -1, 340, accuracy: 0.0001)
        XCTAssertNil(geometry.fallbackSeparatorMaskFrame(
            totalWidth: size.width,
            height: size.height,
            selectedSeparatorGap: 0...40
        ))
    }

    func testTabBarSeparatorSegmentsClampGapIntoBounds() {
        var segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: -20...40)
        XCTAssertEqual(segments.left, 0, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 60, accuracy: 0.0001)

        segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: 25...120)
        XCTAssertEqual(segments.left, 25, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 0, accuracy: 0.0001)

        segments = TabBarStyling.separatorSegments(totalWidth: 100, gap: nil)
        XCTAssertEqual(segments.left, 100, accuracy: 0.0001)
        XCTAssertEqual(segments.right, 0, accuracy: 0.0001)
    }

    @MainActor
    func testPaneDropOverlayDoesNotResizeHostedContentDuringHover() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let model = DropZoneModel()
        let probeView = LayoutProbeView(frame: .zero)
        let hostingView = NSHostingView(
            rootView: PaneDropInteractionHarness(
                model: model,
                probeView: probeView
            )
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let initialFrame = probeView.frame
        let initialSizeChanges = probeView.sizeChangeCount
        let initialOriginChanges = probeView.originChangeCount

        model.zone = .left
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Drag-hover overlays must not resize the hosted pane content"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Drag-hover overlays must not move the hosted pane content"
        )

        model.zone = .bottom
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(probeView.frame, initialFrame)
        XCTAssertEqual(
            probeView.sizeChangeCount,
            initialSizeChanges,
            "Switching hover targets should keep the hosted pane geometry stable"
        )
        XCTAssertEqual(
            probeView.originChangeCount,
            initialOriginChanges,
            "Switching hover targets should not reposition the hosted pane content"
        )
    }

    @MainActor
    func testTranslucentSplitWrappersStayClear() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            enableAnimations: false,
            chromeColors: .init(backgroundHex: "#11223380")
        )
        let configuration = WorkspaceLayoutConfiguration(appearance: appearance)
        let controller = WorkspaceLayoutController(configuration: configuration)
        _ = controller.createTab(title: "Base")
        guard let sourcePane = controller.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }
        guard controller.splitPane(sourcePane, orientation: .horizontal) != nil else {
            XCTFail("Expected splitPane to create a new pane")
            return
        }

        let hostingView = NSHostingView(
            rootView: WorkspaceLayoutView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        guard let splitView = firstDescendant(ofType: NSSplitView.self, in: hostingView) else {
            XCTFail("Expected split view")
            return
        }
        XCTAssertEqual(splitView.arrangedSubviews.count, 2)

        let dividerBackground = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        XCTAssertNotNil(dividerBackground, "Expected split view to be layer-backed")
        XCTAssertEqual(
            dividerBackground?.alphaComponent ?? 0,
            0,
            accuracy: 0.001,
            "Split root should stay clear so translucent pane chrome is painted only once"
        )

        for container in splitView.arrangedSubviews {
            let background = container.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
            XCTAssertNotNil(background, "Expected arranged subview to be layer-backed")
            XCTAssertEqual(
                background?.alphaComponent ?? -1,
                0,
                accuracy: 0.001,
                "Split-only wrapper containers should stay clear so translucent pane chrome is not composited twice"
            )
        }
    }

    @MainActor
    func testSplitContentAlphaMatchesSinglePane() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            enableAnimations: false,
            chromeColors: .init(backgroundHex: "#11223380")
        )
        let expectedAlpha = CGFloat(128.0 / 255.0)
        let samplePoint = NSPoint(x: 100, y: 100)

        let singlePaneController = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(appearance: appearance)
        )
        _ = singlePaneController.createTab(title: "Base")

        guard let singlePaneAlpha = renderedAlpha(
            for: singlePaneController,
            samplePoint: samplePoint
        ) else {
            XCTFail("Expected single-pane rendered alpha")
            return
        }
        XCTAssertEqual(
            singlePaneAlpha,
            expectedAlpha,
            accuracy: 0.03,
            "Single-pane content should preserve the configured translucent alpha"
        )

        let splitController = WorkspaceLayoutController(
            configuration: WorkspaceLayoutConfiguration(appearance: appearance)
        )
        _ = splitController.createTab(title: "Base")
        guard let sourcePane = splitController.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }
        guard splitController.splitPane(sourcePane, orientation: .horizontal) != nil else {
            XCTFail("Expected splitPane to create a new pane")
            return
        }

        guard let splitAlpha = renderedAlpha(
            for: splitController,
            samplePoint: samplePoint
        ) else {
            XCTFail("Expected split rendered alpha")
            return
        }

        XCTAssertEqual(
            splitAlpha,
            singlePaneAlpha,
            accuracy: 0.03,
            "Split mode should render the same content alpha as single-pane mode"
        )
    }

    @MainActor
    func testTabBarDragZoneFocusesInactivePaneInMinimalMode() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = true
        view.isFocusedPane = false

        var focused = false
        var dragged = false
        view.onSingleClick = {
            focused = true
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let event = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        view.mouseDown(with: event)

        XCTAssertTrue(focused, "Inactive-pane drag zone should focus the pane before starting a window drag")
        XCTAssertFalse(dragged, "Inactive-pane focus click should not immediately begin a window drag")
        XCTAssertFalse(view.mouseDownCanMoveWindow, "Inactive-pane drag zone should not advertise window dragging to AppKit")
    }

    @MainActor
    func testTabBarDragZoneMinimalModeNeverRequestsNewTabAfterSingleThenDoubleClick() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = true
        view.isFocusedPane = true

        var requestedNewTab = false
        var dragged = false
        view.onDoubleClick = {
            requestedNewTab = true
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let firstDown = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        let firstUp = try makeMouseEvent(
            type: .leftMouseUp,
            in: view,
            at: NSPoint(x: 20, y: 15),
            clickCount: 1
        )
        let doubleClick = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 2)

        view.mouseDown(with: firstDown)
        view.mouseUp(with: firstUp)
        view.mouseDown(with: doubleClick)

        XCTAssertFalse(requestedNewTab, "Minimal-mode drag zone double-clicks must not request new tabs")
        XCTAssertFalse(dragged, "A plain click followed by a double-click should not start a window drag")
    }

    @MainActor
    func testTabBarDragZoneDoubleClickDoesNotRequestNewTabInMinimalMode() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = true
        view.isFocusedPane = true

        var requestedNewTab = false
        var dragged = false
        view.onDoubleClick = {
            requestedNewTab = true
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let event = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 2)
        view.mouseDown(with: event)

        XCTAssertFalse(requestedNewTab, "Minimal-mode drag zone double-click should behave like titlebar chrome, not new-tab chrome")
        XCTAssertFalse(dragged, "Minimal-mode double-click should not start a window drag")
    }

    @MainActor
    func testTabBarDragZoneSingleClickDoesNotRequestNewTabInStandardMode() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = false
        view.isFocusedPane = true

        var newTabCount = 0
        var dragged = false
        view.onDoubleClick = {
            newTabCount += 1
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let event = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        view.mouseDown(with: event)

        XCTAssertEqual(newTabCount, 0, "Standard-mode drag zone single click should wait for a double-click before creating a tab")
        XCTAssertFalse(dragged, "Standard-mode drag zone single click should not begin a window drag")
    }

    @MainActor
    func testTabBarDragZoneSingleClickFocusesInactivePaneInStandardMode() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = false
        view.isFocusedPane = false

        var focused = false
        var newTabCount = 0
        var dragged = false
        view.onSingleClick = {
            focused = true
            return true
        }
        view.onDoubleClick = {
            newTabCount += 1
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let event = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        view.mouseDown(with: event)

        XCTAssertTrue(focused, "Standard-mode inactive-pane single click should focus the pane")
        XCTAssertEqual(newTabCount, 0, "Standard-mode inactive-pane single click should not create a tab")
        XCTAssertFalse(dragged, "Standard-mode inactive-pane single click should not begin a window drag")
    }

    @MainActor
    func testTabBarDragZoneStandardModeDoubleClickCreatesOnlyOneTab() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = false
        view.isFocusedPane = true

        var newTabCount = 0
        view.onDoubleClick = {
            newTabCount += 1
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let firstDown = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        let firstUp = try makeMouseEvent(
            type: .leftMouseUp,
            in: view,
            at: NSPoint(x: 20, y: 15),
            clickCount: 1
        )
        let secondDown = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 2)

        view.mouseDown(with: firstDown)
        view.mouseUp(with: firstUp)
        view.mouseDown(with: secondDown)

        XCTAssertEqual(newTabCount, 1, "A standard-mode double-click should create exactly one tab")
    }

    @MainActor
    func testTabBarTrailingEmptyChromeCapturesOnlyEmptyArea() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        view.hitRegion = .trailingEmptyChrome(
            tabFrames: [CGRect(x: 10, y: 0, width: 90, height: 30)],
            reservedTrailingWidth: 48
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        view.hitTestEventTypeOverride = .leftMouseDown
        XCTAssertNil(view.hitTest(NSPoint(x: 40, y: 15)), "The empty chrome catcher must not cover tabs")
        XCTAssertNil(view.hitTest(NSPoint(x: 300, y: 15)), "The empty chrome catcher must not cover the action button lane")
        XCTAssertIdentical(view.hitTest(NSPoint(x: 140, y: 15)), view)
    }

    @MainActor
    func testTabBarDragZoneKeepsFocusedPaneWindowDragInMinimalMode() throws {
        let view = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        view.isMinimalMode = true
        view.isFocusedPane = true

        var focused = false
        var dragged = false
        view.onSingleClick = {
            focused = true
            return true
        }
        view.performWindowDrag = { _ in
            dragged = true
            return true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        contentView.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        let event = try makeLeftMouseDownEvent(in: view, at: NSPoint(x: 20, y: 15), clickCount: 1)
        let dragEvent = try makeMouseEvent(
            type: .leftMouseDragged,
            in: view,
            at: NSPoint(x: 30, y: 15),
            clickCount: 1
        )
        view.mouseDown(with: event)
        view.mouseDragged(with: dragEvent)

        XCTAssertFalse(focused, "Focused-pane drag zone should not bounce through first-click focus")
        XCTAssertTrue(dragged, "Focused-pane drag zone should continue to start window drags in minimal mode")
        XCTAssertFalse(view.mouseDownCanMoveWindow, "Focused-pane drag zone must not advertise window dragging to AppKit or AppKit steals mouseUp and breaks new-tab double-clicks")
    }

    private func withShortcutHintDefaultsSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "CMUXLayoutShortcutHintPolicyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func shortcutData(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> Data {
        let payload: [String: Any] = [
            "key": key,
            "command": command,
            "shift": shift,
            "option": option,
            "control": control
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func firstDescendant<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = firstDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func waitForDescendant<T: NSView>(
        ofType type: T.Type,
        in root: NSView,
        containingWindowPoint point: NSPoint,
        timeout: TimeInterval = 1.0,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let match = firstDescendant(
                ofType: type,
                in: root,
                containingWindowPoint: point,
                where: predicate
            ) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return firstDescendant(
            ofType: type,
            in: root,
            containingWindowPoint: point,
            where: predicate
        )
    }

    @MainActor
    private func firstDescendant<T: NSView>(
        ofType type: T.Type,
        in root: NSView,
        containingWindowPoint point: NSPoint,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = root as? T {
            let frameInWindow = root.convert(root.bounds, to: nil)
            if frameInWindow.contains(point), predicate(match) {
                return match
            }
        }
        for subview in root.subviews {
            if let match = firstDescendant(
                ofType: type,
                in: subview,
                containingWindowPoint: point,
                where: predicate
            ) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func renderedAlpha(
        for controller: WorkspaceLayoutController,
        samplePoint: NSPoint,
        size: NSSize = NSSize(width: 800, height: 600)
    ) -> CGFloat? {
        let hostingView = NSHostingView(
            rootView: WorkspaceLayoutView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else { return nil }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        return renderedColor(in: hostingView, at: samplePoint)?.alphaComponent
    }

    @MainActor
    private func renderedTabBarIndicatorSaturation(isFocused: Bool) -> CGFloat? {
        renderedTabBarValue(isFocused: isFocused) { hostingView in
            let sampleRect = NSRect(x: 4, y: 0, width: 44, height: 4)
            return maximumSaturation(in: hostingView, sampleRect: sampleRect)
        }
    }

    @MainActor
    private func renderedTabBarIndicatorWidth(isFocused: Bool) -> CGFloat? {
        renderedTabBarValue(isFocused: isFocused) { hostingView in
            let sampleRect = NSRect(x: 0, y: 0, width: 80, height: 4)
            return highSaturationWidth(in: hostingView, sampleRect: sampleRect)
        }
    }

    @MainActor
    private func renderedSplitButtonLaneTopSaturation() -> CGFloat? {
        let buttonCount = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
        let size = NSSize(width: 240, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#111111",
                tabBarBackgroundHex: "#181818",
                splitButtonBackdropHex: "#242424",
                borderHex: "#666666"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the controls",
                    icon: nil
                )
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            let sampleRect = NSRect(x: laneStartX + 4, y: 0, width: 40, height: 4)
            return maximumSaturation(in: hostingView, sampleRect: sampleRect)
        }
    }

    @MainActor
    private func renderedSplitButtonBackdropFadeVerticalColorDelta() -> CGFloat? {
        let size = NSSize(width: 360, height: 28)
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#FFFFFF",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(title: "", icon: nil)
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let sampleX = size.width - 124
            guard let top = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: sampleX, y: 6)
            )?.usingColorSpace(.sRGB),
                  let bottom = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: sampleX, y: size.height - 6)
                  )?.usingColorSpace(.sRGB) else {
                return nil
            }

            return abs(top.redComponent - bottom.redComponent)
                + abs(top.greenComponent - bottom.greenComponent)
                + abs(top.blueComponent - bottom.blueComponent)
                + abs(top.alphaComponent - bottom.alphaComponent)
        }
    }

    @MainActor
    private func renderedSplitButtonLaneSolidBackdropBrightness() -> CGFloat? {
        let buttonCount = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
        let size = NSSize(width: 240, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#FFFFFF",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(title: "", icon: nil)
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            guard let color = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: laneStartX + 2, y: size.height / 2)
            )?.usingColorSpace(.sRGB) else {
                return nil
            }
            return brightness(of: color)
        }
    }

    @MainActor
    private func renderedSplitButtonContentFadeStartBackdropBrightness() -> CGFloat? {
        let buttonCount = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
        let size = NSSize(width: 240, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let contentFadeWidth = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect.default.contentFadeWidth
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#FFFFFF",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the controls",
                    icon: nil
                )
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            guard let color = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: laneStartX - contentFadeWidth + 2, y: size.height / 2)
            )?.usingColorSpace(.sRGB) else {
                return nil
            }
            return brightness(of: color)
        }
    }

    @MainActor
    private func renderedSplitButtonContentFadeStartSaturation() -> CGFloat? {
        let buttonCount = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
        let size = NSSize(width: 240, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let contentFadeWidth = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect.default.contentFadeWidth
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#000000",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the controls",
                    icon: nil
                )
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            let sampleRect = NSRect(
                x: laneStartX - contentFadeWidth + 2,
                y: 0,
                width: 8,
                height: 4
            )
            return maximumSaturation(in: hostingView, sampleRect: sampleRect)
        }
    }

    @MainActor
    private func renderedSelectedIndicatorBackdropBrightnesses() -> (leading: CGFloat, trailing: CGFloat)? {
        let buttonCount = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
        let size = NSSize(width: 240, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let fadeWidth = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect.default.contentFadeWidth
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            splitButtonBackdropEffect: .default,
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#000000",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the controls",
                    icon: nil
                )
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            guard let leading = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: laneStartX - fadeWidth + 4, y: 0)
            )?.usingColorSpace(.sRGB),
                  let trailing = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: laneStartX - 4, y: 0)
                  )?.usingColorSpace(.sRGB) else {
                return nil
            }

            return (
                leading: brightness(of: leading),
                trailing: brightness(of: trailing)
            )
        }
    }

    @MainActor
    private func renderedSharedBackdropActionLaneSurfaceAlpha() -> CGFloat? {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let appearance = sharedBackdropManyActionAppearance(
            tabBarHeight: size.height,
            buttonCount: buttonCount
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let leading = SurfaceItem(title: "", icon: nil)
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the full action button lane",
                    icon: nil
                )
                pane.tabs = [leading, selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let laneStartX = size.width - splitButtonLaneWidth
            guard let color = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: laneStartX + 2, y: 2)
            )?.usingColorSpace(.sRGB) else {
                return nil
            }
            return color.alphaComponent
        }
    }

    @MainActor
    private func renderedEscapedSplitButtonBrightnessOutsideActionLane() -> CGFloat? {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: size.height,
            tabMaxWidth: 40,
            splitButtons: manySplitActionButtons(count: buttonCount),
            splitButtonBackdropEffect: .init(
                style: .translucentChrome,
                fadeWidth: 99.75,
                contentFadeWidth: 28.875,
                solidWidth: 23.875,
                fadeRampStartFraction: 0.60,
                leadingOpacity: 0,
                trailingOpacity: 0.8625,
                contentOcclusionFraction: 0.6875,
                masksTabContent: true
            ),
            chromeColors: .init(
                backgroundHex: "#000000",
                tabBarBackgroundHex: "#000000",
                splitButtonBackdropHex: "#000000",
                borderHex: "#00000000"
            )
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let selected = SurfaceItem(title: "", icon: nil)
                pane.tabs = [selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            maximumBrightness(
                in: hostingView,
                sampleRect: NSRect(
                    x: 100,
                    y: 5,
                    width: size.width - splitButtonLaneWidth - 108,
                    height: size.height - 10
                )
            )
        }
    }

    @MainActor
    private func renderedSharedBackdropActionLaneBottomSeparatorAlphas() -> (
        fadeStart: CGFloat,
        beforeRamp: CGFloat,
        afterRamp: CGFloat,
        fadeEnd: CGFloat,
        solidStart: CGFloat,
        solid: CGFloat
    )? {
        let buttonCount = 28
        let size = NSSize(width: 360, height: 28)
        let splitButtonLaneWidth = visibleSplitButtonLaneWidth(size: size, buttonCount: buttonCount)
        let separatorFadeWidth: CGFloat = 99.75
        let rampStartFraction: CGFloat = 0.60
        let contentOcclusionWidth = TabBarStyling.splitButtonContentOcclusionWidth(
            visibleLaneWidth: splitButtonLaneWidth,
            contentOcclusionFraction: 0.6875
        )
        let solidWidth = max(splitButtonLaneWidth, contentOcclusionWidth)
        let appearance = sharedBackdropManyActionAppearance(
            tabBarHeight: size.height,
            buttonCount: buttonCount,
            borderHex: "#FFFFFF80",
            tabMaxWidth: size.width
        )

        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            showSplitButtons: true,
            size: size,
            configurePane: { pane in
                let leading = SurfaceItem(title: "", icon: nil)
                let selected = SurfaceItem(
                    title: "selected tab title that reaches under the full action button lane",
                    icon: nil
                )
                pane.tabs = [leading, selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let separatorY = size.height - 0.5
            let fadeStartX = size.width - solidWidth - separatorFadeWidth
            let rampStartX = fadeStartX + separatorFadeWidth * rampStartFraction
            let solidStartX = size.width - solidWidth
            guard let fadeStart = renderedColorInViewCoordinates(
                in: hostingView,
                at: NSPoint(x: fadeStartX + 2, y: separatorY)
            )?.usingColorSpace(.sRGB)?.alphaComponent,
                  let beforeRamp = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: rampStartX - 2, y: separatorY)
                  )?.usingColorSpace(.sRGB)?.alphaComponent,
                  let afterRamp = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: rampStartX + 16, y: separatorY)
                  )?.usingColorSpace(.sRGB)?.alphaComponent,
                  let fadeEnd = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: solidStartX - 2, y: separatorY)
                  )?.usingColorSpace(.sRGB)?.alphaComponent,
                  let solidStart = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: solidStartX + 2, y: separatorY)
                  )?.usingColorSpace(.sRGB)?.alphaComponent,
                  let solid = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: size.width - 6, y: separatorY)
                  )?.usingColorSpace(.sRGB)?.alphaComponent else {
                return nil
            }
            return (
                fadeStart: fadeStart,
                beforeRamp: beforeRamp,
                afterRamp: afterRamp,
                fadeEnd: fadeEnd,
                solidStart: solidStart,
                solid: solid
            )
        }
    }

    private func sharedBackdropManyActionAppearance(
        tabBarHeight: CGFloat,
        buttonCount: Int,
        borderHex: String = "#66666680",
        tabMaxWidth: CGFloat = 220,
        separatorFadeWidth: CGFloat? = nil
    ) -> WorkspaceLayoutConfiguration.Appearance {
        WorkspaceLayoutConfiguration.Appearance(
            tabBarHeight: tabBarHeight,
            tabMaxWidth: tabMaxWidth,
            splitButtons: manySplitActionButtons(count: buttonCount),
            splitButtonBackdropEffect: .init(
                style: .translucentChrome,
                fadeWidth: 99.75,
                contentFadeWidth: 28.875,
                solidWidth: 23.875,
                separatorFadeWidth: separatorFadeWidth,
                fadeRampStartFraction: 0.60,
                leadingOpacity: 0,
                trailingOpacity: 0.8625,
                contentOcclusionFraction: 0.6875,
                masksTabContent: true
            ),
            chromeColors: .init(
                backgroundHex: "#242424B8",
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            ),
            usesSharedBackdrop: true
        )
    }

    private func manySplitActionButtons(count: Int) -> [WorkspaceLayoutConfiguration.SplitActionButton] {
        (0..<count).map { index in
            WorkspaceLayoutConfiguration.SplitActionButton(
                id: "many-action-\(index)",
                icon: .systemImage("terminal"),
                tooltip: "Action \(index)",
                action: .custom("many-action-\(index)")
            )
        }
    }

    private func visibleSplitButtonLaneWidth(size: NSSize, buttonCount: Int) -> CGFloat {
        TabBarLayout(
            tabBarHeight: size.height,
            availableWidth: size.width,
            splitButtonCount: buttonCount,
            splitButtonLaneVisible: true,
            reservesSplitButtonLane: true,
            measuredSplitButtonLaneWidth: TabBarStyling.splitButtonsBackdropWidth(buttonCount: buttonCount)
        ).visibleSplitButtonLaneWidth
    }

    @MainActor
    private func renderedSelectedTabLeftSeparatorAlphas() -> (top: CGFloat, bottom: CGFloat)? {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: "#00000000",
                tabBarBackgroundHex: "#00000000",
                borderHex: "#FFFFFF80"
            )
        )
        return renderedTabBarValue(
            isFocused: true,
            appearance: appearance,
            configurePane: { pane in
                let leading = SurfaceItem(title: "", icon: nil)
                let selected = SurfaceItem(title: "", icon: nil)
                pane.tabs = [leading, selected]
                pane.selectedTabId = selected.id
            }
        ) { hostingView in
            let separatorX = TabBarMetrics.tabMinWidth - 0.5
            guard let top = renderedColorInViewCoordinates(in: hostingView, at: NSPoint(x: separatorX, y: 4))?
                .usingColorSpace(.sRGB)?
                .alphaComponent,
                  let bottom = renderedColorInViewCoordinates(
                    in: hostingView,
                    at: NSPoint(x: separatorX, y: TabBarMetrics.barHeight - 0.5)
                  )?
                .usingColorSpace(.sRGB)?
                .alphaComponent else {
                return nil
            }
            return (top: top, bottom: bottom)
        }
    }

    @MainActor
    private func renderedColorInViewCoordinates(in view: NSView, at point: NSPoint) -> NSColor? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, integralBounds.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, integralBounds.height)
        let x = Int((point.x * scaleX).rounded(.down))
        let y = Int((point.y * scaleY).rounded(.down))
        guard x >= 0,
              y >= 0,
              x < bitmap.pixelsWide,
              y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)
    }
    @MainActor
    private func renderedTabBarValue<T>(
        isFocused: Bool,
        appearance: WorkspaceLayoutConfiguration.Appearance = .default,
        showSplitButtons: Bool = false,
        size: NSSize? = nil,
        configurePane: ((PaneState) -> Void)? = nil,
        extract: (NSView) -> T?
    ) -> T? {
        let controller = WorkspaceLayoutController(configuration: WorkspaceLayoutConfiguration(appearance: appearance))
        guard let pane = controller.internalController.rootNode.allPanes.first else { return nil }
        if let configurePane {
            configurePane(pane)
        } else {
            let tab = SurfaceItem(title: "", icon: nil)
            pane.tabs = [tab]
            pane.selectedTabId = tab.id
        }

        let size = size ?? NSSize(width: 160, height: TabBarMetrics.barHeight)
        let hostingView = NSHostingView(
            rootView: TabBarView(pane: pane, isFocused: isFocused, showSplitButtons: showSplitButtons)
                .environment(controller)
                .environment(controller.internalController)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else { return nil }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        return extract(hostingView)
    }

    @MainActor
    private func maximumSaturation(in view: NSView, sampleRect: NSRect? = nil) -> CGFloat? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let rect = sampleRect ?? integralBounds
        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, integralBounds.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, integralBounds.height)
        let minX = max(0, Int(floor(rect.minX * scaleX)))
        let maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX * scaleX)))
        let minY = max(0, Int(floor(rect.minY * scaleY)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY * scaleY)))

        var maximum: CGFloat = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.05 else { continue }
                let alpha = min(max(rgb.alphaComponent, 0), 1)
                let red = rgb.redComponent * alpha
                let green = rgb.greenComponent * alpha
                let blue = rgb.blueComponent * alpha
                let high = max(red, green, blue)
                guard high > 0.01 else { continue }
                let low = min(red, green, blue)
                let saturation = (high - low) / high
                maximum = max(maximum, saturation)
            }
        }
        return maximum
    }

    @MainActor
    private func maximumBrightness(in view: NSView, sampleRect: NSRect) -> CGFloat? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, integralBounds.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, integralBounds.height)
        let minX = max(0, Int(floor(sampleRect.minX * scaleX)))
        let maxX = min(bitmap.pixelsWide, Int(ceil(sampleRect.maxX * scaleX)))
        let minY = max(0, Int(floor(sampleRect.minY * scaleY)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil(sampleRect.maxY * scaleY)))

        var maximum: CGFloat = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.05 else { continue }
                let alpha = min(max(rgb.alphaComponent, 0), 1)
                maximum = max(
                    maximum,
                    max(
                        rgb.redComponent * alpha,
                        rgb.greenComponent * alpha,
                        rgb.blueComponent * alpha
                    )
                )
            }
        }
        return maximum
    }

    private func brightness(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let alpha = min(max(rgb.alphaComponent, 0), 1)
        guard alpha > 0.01 else { return 0 }
        return max(
            rgb.redComponent * alpha,
            rgb.greenComponent * alpha,
            rgb.blueComponent * alpha
        )
    }

    @MainActor
    private func highSaturationWidth(in view: NSView, sampleRect: NSRect) -> CGFloat? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, integralBounds.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, integralBounds.height)
        let minX = max(0, Int(floor(sampleRect.minX * scaleX)))
        let maxX = min(bitmap.pixelsWide, Int(ceil(sampleRect.maxX * scaleX)))
        let minY = max(0, Int(floor(sampleRect.minY * scaleY)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil(sampleRect.maxY * scaleY)))

        var activeColumnCount = 0
        for x in minX..<maxX {
            var hasIndicatorPixel = false
            for y in minY..<maxY {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.05 else { continue }
                let alpha = min(max(rgb.alphaComponent, 0), 1)
                let red = rgb.redComponent * alpha
                let green = rgb.greenComponent * alpha
                let blue = rgb.blueComponent * alpha
                let high = max(red, green, blue)
                guard high > 0.01 else { continue }
                let low = min(red, green, blue)
                if (high - low) / high > 0.4 {
                    hasIndicatorPixel = true
                    break
                }
            }
            if hasIndicatorPixel {
                activeColumnCount += 1
            }
        }
        return CGFloat(activeColumnCount) / scaleX
    }

    @MainActor
    private func renderedColor(in view: NSView, at point: NSPoint) -> NSColor? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        guard x >= 0,
              y >= 0,
              x < bitmap.pixelsWide,
              y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)
    }

    @MainActor
    private func makeLeftMouseDownEvent(
        in view: NSView,
        at point: NSPoint,
        clickCount: Int
    ) throws -> NSEvent {
        try makeMouseEvent(type: .leftMouseDown, in: view, at: point, clickCount: clickCount)
    }

    @MainActor
    private func makeMouseEvent(
        type: NSEvent.EventType,
        in view: NSView,
        at point: NSPoint,
        clickCount: Int
    ) throws -> NSEvent {
        guard let window = view.window else {
            throw NSError(domain: "CMUXLayoutTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing window"])
        }
        let pointInWindow = view.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else {
            throw NSError(domain: "CMUXLayoutTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create mouse event"])
        }
        return event
    }

    func testCanvasDocumentDefaultsToScrollingColumns() {
        let paneA = PaneID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
        let paneB = PaneID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

        let document = CanvasDocument.defaultScrollingColumns(
            panes: [paneA, paneB],
            columnWidth: 500,
            columnHeight: 300,
            gap: 24
        )

        XCTAssertEqual(document.policy, .scrollingColumns)
        XCTAssertEqual(document.items.map(\.content), [.pane(paneA), .pane(paneB)])
        XCTAssertEqual(document.items.map(\.frame.x), [0, 524])
        XCTAssertEqual(document.items.map(\.frame.width), [500, 500])
        XCTAssertEqual(document.items.map(\.isNativeResolution), [true, true])
    }

    func testMovingCanvasItemSwitchesPolicyToFreeform() throws {
        let pane = PaneID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
        var document = CanvasDocument.defaultScrollingColumns(panes: [pane])
        let itemID = try XCTUnwrap(document.items.first?.id)
        let targetFrame = PixelRect(x: 80, y: 60, width: 640, height: 360)

        document.moveItem(itemID, to: targetFrame)

        XCTAssertEqual(document.policy, .freeform)
        XCTAssertEqual(document.items.first?.frame, targetFrame)
    }

    @MainActor
    func testControllerStartsWithScrollingColumnCanvas() throws {
        let controller = WorkspaceLayoutController()
        let canvas = controller.canvasSnapshot()

        XCTAssertEqual(canvas.policy, .scrollingColumns)
        XCTAssertEqual(canvas.items.count, controller.allPaneIds.count)
        XCTAssertEqual(canvas.items.first?.isNativeResolution, true)
    }

    @MainActor
    func testControllerFreeformCanvasPreservesMovedPaneFrame() throws {
        let controller = WorkspaceLayoutController()
        let itemID = try XCTUnwrap(controller.canvasSnapshot().items.first?.id)
        let movedFrame = PixelRect(x: 42, y: 24, width: 700, height: 400)

        controller.moveCanvasItem(itemID, to: movedFrame)

        let canvas = controller.canvasSnapshot()
        XCTAssertEqual(canvas.policy, .freeform)
        XCTAssertEqual(canvas.items.first?.frame, movedFrame)
    }

    @MainActor
    func testControllerFreeformCanvasPreservesResizedPaneFrame() throws {
        let controller = WorkspaceLayoutController()
        let itemID = try XCTUnwrap(controller.canvasSnapshot().items.first?.id)
        let resizedFrame = PixelRect(x: 0, y: 0, width: 960, height: 540)

        controller.resizeCanvasItem(itemID, to: resizedFrame)

        let canvas = controller.canvasSnapshot()
        XCTAssertEqual(canvas.policy, .freeform)
        XCTAssertEqual(canvas.items.first?.frame, resizedFrame)
    }

    @MainActor
    func testControllerCanvasItemIDsRemainStableAcrossSync() throws {
        let controller = WorkspaceLayoutController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        _ = controller.splitPane(sourcePaneId, orientation: .horizontal)

        let firstSnapshot = controller.canvasSnapshot()
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 900, height: 600))
        let secondSnapshot = controller.canvasSnapshot()

        let firstIdsByContent = Dictionary(uniqueKeysWithValues: firstSnapshot.items.map {
            (String(describing: $0.content), $0.id)
        })
        let secondIdsByContent = Dictionary(uniqueKeysWithValues: secondSnapshot.items.map {
            (String(describing: $0.content), $0.id)
        })
        XCTAssertEqual(firstIdsByContent, secondIdsByContent)
    }

    @MainActor
    func testScrollingColumnsCanvasUsesIndependentColumnsAfterSplitGeometry() throws {
        let controller = WorkspaceLayoutController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        _ = controller.splitPane(sourcePaneId, orientation: .horizontal)
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 900, height: 600))

        let canvas = controller.canvasSnapshot()

        XCTAssertEqual(canvas.policy, .scrollingColumns)
        XCTAssertEqual(canvas.items.count, 2)
        XCTAssertEqual(canvas.items.map(\.frame.x), [0, 916])
        XCTAssertEqual(canvas.items.map(\.frame.width), [900, 900])
    }

    @MainActor
    func testCanvasOverviewNavigationTracksCanvasFrames() throws {
        let controller = WorkspaceLayoutController()
        _ = controller.createTab(title: "Base")
        let sourcePaneId = try XCTUnwrap(controller.focusedPaneId)
        _ = controller.splitPane(sourcePaneId, orientation: .horizontal)
        controller.enterCanvasOverview(policy: .scrollingColumns, scale: 0.35)

        let initialID = try XCTUnwrap(controller.canvasSnapshot().items.first?.id)
        XCTAssertTrue(controller.focusCanvasItem(initialID))
        let nextID = try XCTUnwrap(controller.navigateCanvasFocus(direction: .right))

        XCTAssertNotEqual(nextID, initialID)
        XCTAssertEqual(controller.focusedCanvasItemID, nextID)
    }

    func testCanvasResizeHitAreaUsesPackageOwnedCornersAndEdges() {
        let hitArea = CanvasResizeHitArea(
            cardSize: CGSize(width: 320, height: 220),
            edgeHitSize: 16,
            cornerHitSize: 44
        )

        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 32, y: 32)), .topLeft)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 288, y: 32)), .topRight)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 32, y: 188)), .bottomLeft)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 288, y: 188)), .bottomRight)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 8, y: 110)), .left)
        XCTAssertEqual(hitArea.handle(at: CGPoint(x: 312, y: 110)), .right)
        XCTAssertNil(hitArea.handle(at: CGPoint(x: 160, y: 110)))
    }

    func testCanvasDragPreservesCursorOffsetAndSnapsToGrid() {
        let itemID = LayoutItemID()
        let item = CanvasItem(
            id: itemID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 13, y: 17, width: 300, height: 200)
        )
        let transform = CanvasTransform(
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            scale: 1
        )
        let session = CanvasGeometryEngine.beginDrag(
            itemID: itemID,
            frame: item.frame,
            pointerCanvasPoint: CGPoint(x: 23, y: 37),
            transform: transform
        )

        let result = CanvasGeometryEngine.updateDrag(
            session: session,
            pointerCanvasPoint: CGPoint(x: 95, y: 83),
            transform: transform,
            items: [item],
            configuration: CanvasInteractionConfiguration(
                grid: CanvasGrid(spacing: 8, majorEvery: 8),
                minimumFrameSize: CGSize(width: 100, height: 100)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 84, y: 64, width: 300, height: 200))
    }

    func testCanvasDragEmitsVerticalAlignmentGuide() {
        let movingID = LayoutItemID()
        let targetID = LayoutItemID()
        let moving = CanvasItem(
            id: movingID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 40, y: 20, width: 100, height: 80)
        )
        let target = CanvasItem(
            id: targetID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 200, y: 300, width: 120, height: 90)
        )
        let transform = CanvasTransform(
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            scale: 1
        )
        let session = CanvasGeometryEngine.beginDrag(
            itemID: movingID,
            frame: moving.frame,
            pointerCanvasPoint: CGPoint(x: 50, y: 30),
            transform: transform
        )

        let result = CanvasGeometryEngine.updateDrag(
            session: session,
            pointerCanvasPoint: CGPoint(x: 111, y: 30),
            transform: transform,
            items: [moving, target],
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                alignmentSnapDistanceInScreenPoints: 6,
                minimumFrameSize: CGSize(width: 80, height: 60)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 100, y: 20, width: 100, height: 80))
        XCTAssertEqual(result.guides.first?.axis, .vertical)
        XCTAssertEqual(result.guides.first?.position, 200)
    }

    func testCanvasMoveFrameUsesScaledWindowTranslationAndSnapsToGrid() {
        let itemID = LayoutItemID()
        let item = CanvasItem(
            id: itemID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 13, y: 17, width: 300, height: 200)
        )

        let result = CanvasGeometryEngine.moveFrame(
            itemID: itemID,
            baseFrame: item.frame,
            canvasTranslation: CGSize(width: 36, height: 23),
            scale: 0.5,
            items: [item],
            configuration: CanvasInteractionConfiguration(
                grid: CanvasGrid(spacing: 8, majorEvery: 8),
                minimumFrameSize: CGSize(width: 100, height: 100)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 84, y: 64, width: 300, height: 200))
    }

    func testCanvasMoveFrameDoesNotClampToViewport() {
        let itemID = LayoutItemID()
        let item = CanvasItem(
            id: itemID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 40, y: 32, width: 300, height: 200)
        )

        let result = CanvasGeometryEngine.moveFrame(
            itemID: itemID,
            baseFrame: item.frame,
            documentTranslation: CGSize(width: -240, height: -160),
            items: [item],
            scale: 1,
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                minimumFrameSize: CGSize(width: 100, height: 100)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: -200, y: -128, width: 300, height: 200))
    }

    func testCanvasViewportAnchoredTransformLetsItemsRenderOutOfBounds() {
        let item = CanvasItem(
            content: .pane(PaneID()),
            frame: PixelRect(x: -320, y: -160, width: 600, height: 400)
        )
        let viewport = CanvasViewport(
            visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800),
            scale: 1
        )
        let bounds = CanvasGeometryEngine.viewportAnchoredContentBounds(
            for: [item],
            scale: 1,
            viewport: viewport,
            viewportSize: CGSize(width: 1_200, height: 800),
            padding: 24
        )
        let transform = CanvasTransform(
            documentBounds: bounds.documentBounds,
            scale: 1,
            padding: 24,
            documentOrigin: CGPoint(x: CGFloat(viewport.visibleRect.x), y: CGFloat(viewport.visibleRect.y))
        )

        let canvasRect = transform.canvasRect(forDocumentFrame: item.frame)

        XCTAssertEqual(transform.documentPoint(forCanvasPoint: CGPoint(x: 24, y: 24)), .zero)
        XCTAssertLessThan(canvasRect.minX, 0)
        XCTAssertLessThan(canvasRect.minY, 0)
        XCTAssertGreaterThan(canvasRect.maxX, 0)
        XCTAssertGreaterThan(canvasRect.maxY, 0)
    }

    func testCanvasViewportAnchoredBoundsExpandTowardPositiveOffscreenItems() {
        let item = CanvasItem(
            content: .pane(PaneID()),
            frame: PixelRect(x: 2_000, y: 900, width: 600, height: 400)
        )
        let viewport = CanvasViewport(
            visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800),
            scale: 0.5
        )

        let bounds = CanvasGeometryEngine.viewportAnchoredContentBounds(
            for: [item],
            scale: 0.5,
            viewport: viewport,
            viewportSize: CGSize(width: 1_200, height: 800),
            padding: 24
        )
        let transform = CanvasTransform(
            documentBounds: bounds.documentBounds,
            scale: 0.5,
            padding: 24,
            documentOrigin: CGPoint(x: CGFloat(viewport.visibleRect.x), y: CGFloat(viewport.visibleRect.y))
        )
        let canvasRect = transform.canvasRect(forDocumentFrame: item.frame)

        XCTAssertGreaterThan(bounds.size.width, 1_200)
        XCTAssertEqual(canvasRect.minX, 1_024, accuracy: 0.0001)
        XCTAssertEqual(canvasRect.minY, 474, accuracy: 0.0001)
    }

    func testCanvasMoveFrameEmitsAlignmentGuides() {
        let movingID = LayoutItemID()
        let targetID = LayoutItemID()
        let moving = CanvasItem(
            id: movingID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 40, y: 20, width: 100, height: 80)
        )
        let target = CanvasItem(
            id: targetID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 200, y: 300, width: 120, height: 90)
        )

        let result = CanvasGeometryEngine.moveFrame(
            itemID: movingID,
            baseFrame: moving.frame,
            canvasTranslation: CGSize(width: 61, height: 0),
            scale: 1,
            items: [moving, target],
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                alignmentSnapDistanceInScreenPoints: 6,
                minimumFrameSize: CGSize(width: 80, height: 60)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 100, y: 20, width: 100, height: 80))
        XCTAssertEqual(result.guides.first?.axis, .vertical)
        XCTAssertEqual(result.guides.first?.position, 200)
    }

    func testCanvasCornerResizeChangesBothDimensions() {
        let itemID = LayoutItemID()
        let item = CanvasItem(
            id: itemID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 80, y: 90, width: 300, height: 200)
        )

        let result = CanvasGeometryEngine.resizeFrame(
            itemID: itemID,
            baseFrame: item.frame,
            canvasTranslation: CGSize(width: 45, height: 75),
            scale: 1,
            handle: .bottomRight,
            items: [item],
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                minimumFrameSize: CGSize(width: 120, height: 100)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 80, y: 90, width: 345, height: 275))
    }

    func testCanvasResizeSnapsActiveEdgeAndEmitsGuide() {
        let movingID = LayoutItemID()
        let targetID = LayoutItemID()
        let moving = CanvasItem(
            id: movingID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 100, y: 120, width: 300, height: 200)
        )
        let target = CanvasItem(
            id: targetID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 450, y: 80, width: 200, height: 240)
        )

        let result = CanvasGeometryEngine.resizeFrame(
            itemID: movingID,
            baseFrame: moving.frame,
            canvasTranslation: CGSize(width: 49, height: 0),
            scale: 1,
            handle: .right,
            items: [moving, target],
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                alignmentSnapDistanceInScreenPoints: 6,
                minimumFrameSize: CGSize(width: 150, height: 120)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 100, y: 120, width: 350, height: 200))
        XCTAssertEqual(result.guides.first?.axis, .vertical)
        XCTAssertEqual(result.guides.first?.position, 450)
    }

    func testCanvasResizeRespectsMinimumSizeFromPackageEngine() {
        let itemID = LayoutItemID()
        let item = CanvasItem(
            id: itemID,
            content: .pane(PaneID()),
            frame: PixelRect(x: 100, y: 100, width: 300, height: 220)
        )

        let result = CanvasGeometryEngine.resizeFrame(
            itemID: itemID,
            baseFrame: item.frame,
            canvasTranslation: CGSize(width: 400, height: 500),
            scale: 1,
            handle: .topLeft,
            items: [item],
            configuration: CanvasInteractionConfiguration(
                grid: nil,
                minimumFrameSize: CGSize(width: 150, height: 120)
            )
        )

        XCTAssertEqual(result.frame, PixelRect(x: 250, y: 200, width: 150, height: 120))
    }

    func testCanvasSurfacePresentationKeepsNativeSizeSeparateFromVisualFrame() {
        let presentation = CanvasSurfacePresentation(
            frameInWindow: CGRect(x: 10, y: 20, width: 400, height: 300),
            nativeContentSize: CGSize(width: 1_000, height: 700),
            scale: 0.4
        )

        XCTAssertEqual(presentation.frameInWindow, CGRect(x: 10, y: 20, width: 400, height: 300))
        XCTAssertEqual(presentation.nativeContentSize, CGSize(width: 1_000, height: 700))
        XCTAssertEqual(presentation.visualContentSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(presentation.horizontalScale, 0.4, accuracy: 0.0001)
        XCTAssertEqual(presentation.verticalScale, 300.0 / 700.0, accuracy: 0.0001)
    }

    @MainActor
    func testCanvasViewportPanningAllowsUnboundedOrigin() {
        let controller = WorkspaceLayoutController()

        controller.panCanvasViewport(
            screenDelta: CGSize(width: 100, height: -50),
            scale: 0.5,
            viewportSize: CGSize(width: 1_200, height: 800)
        )

        let viewport = controller.canvasViewport
        XCTAssertEqual(viewport.visibleRect.x, -200, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.y, 100, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.width, 2_400, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.height, 1_600, accuracy: 0.0001)
    }

    func testCanvasVisibleItemsCullFarOffscreenFrames() {
        let visibleID = LayoutItemID()
        let farID = LayoutItemID()
        let items = [
            CanvasItem(
                id: visibleID,
                content: .group([]),
                frame: PixelRect(x: 20, y: 20, width: 300, height: 200)
            ),
            CanvasItem(
                id: farID,
                content: .group([]),
                frame: PixelRect(x: 1_000_000, y: 1_000_000, width: 300, height: 200)
            )
        ]

        let visible = CanvasGeometryEngine.visibleItems(
            items,
            viewport: CanvasViewport(visibleRect: PixelRect(x: 0, y: 0, width: 1_200, height: 800)),
            viewportSize: CGSize(width: 1_200, height: 800),
            scale: 1
        )

        XCTAssertEqual(visible.map(\.id), [visibleID])
    }

    func testCanvasVisibleDocumentRectTracksViewportOnly() {
        let viewport = CanvasViewport(
            visibleRect: PixelRect(x: -10_000, y: 25_000, width: 1_200, height: 800),
            scale: 0.5
        )

        let rect = CanvasGeometryEngine.visibleDocumentRect(
            viewport: viewport,
            viewportSize: CGSize(width: 1_000, height: 600),
            scale: 0.5,
            overscanScreenPoints: 100
        )

        XCTAssertEqual(rect.origin.x, -10_200, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 24_800, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 2_400, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 1_600, accuracy: 0.0001)
    }

    @MainActor
    func testCanvasViewportZoomKeepsAnchorDocumentPointStable() {
        let controller = WorkspaceLayoutController()
        controller.setCanvasViewport(
            CanvasViewport(
                visibleRect: PixelRect(x: 100, y: 200, width: 1_200, height: 800),
                scale: 0.5
            )
        )

        controller.setCanvasViewportScale(
            0.25,
            viewportSize: CGSize(width: 1_000, height: 600),
            anchorScreenPoint: CGPoint(x: 250, y: 150)
        )

        let viewport = controller.canvasViewport
        XCTAssertEqual(viewport.scale, 0.25, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.x, -400, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.y, -100, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.width, 4_000, accuracy: 0.0001)
        XCTAssertEqual(viewport.visibleRect.height, 2_400, accuracy: 0.0001)
    }

    @MainActor
    func testCanvasSceneSnapshotPromotesFocusedItemToNativeMount() throws {
        let controller = WorkspaceLayoutController()
        let initial = controller.canvasSnapshot()
        let firstID = try XCTUnwrap(initial.items.first?.id)

        XCTAssertTrue(controller.focusCanvasItem(firstID))

        let scene = controller.canvasSceneSnapshot()

        XCTAssertEqual(scene.activeMountDirective?.itemID, firstID)
        XCTAssertEqual(scene.activeMountDirective?.renderMode, .liveNative1x)
        XCTAssertEqual(scene.items.first(where: { $0.id == firstID })?.isFocused, true)
        XCTAssertTrue(scene.items.filter { $0.id != firstID }.allSatisfy { $0.renderMode == .previewTexture })
    }

    @MainActor
    func testCanvasSceneSnapshotSupportsExplicitActiveItemSeparateFromFocus() throws {
        let controller = WorkspaceLayoutController()
        let secondPane = try XCTUnwrap(controller.splitPane(orientation: .horizontal))
        let initial = controller.canvasSnapshot()
        let firstID = try XCTUnwrap(initial.items.first?.id)
        let secondID = LayoutItemID(paneID: secondPane)

        XCTAssertTrue(controller.focusCanvasItem(firstID))

        let scene = controller.canvasSceneSnapshot(activeItemID: secondID)

        XCTAssertEqual(scene.focusedItemID, firstID)
        XCTAssertEqual(scene.activeMountDirective?.itemID, secondID)
        XCTAssertEqual(scene.items.first(where: { $0.id == firstID })?.isFocused, true)
        XCTAssertEqual(scene.items.first(where: { $0.id == secondID })?.renderMode, .liveNative1x)
    }

    @MainActor
    func testCanvasSceneSnapshotKeepsZoomedOverviewAsPreviewOnly() throws {
        let controller = WorkspaceLayoutController()
        let firstID = try XCTUnwrap(controller.canvasSnapshot().items.first?.id)

        XCTAssertTrue(controller.focusCanvasItem(firstID))
        controller.enterCanvasOverview(policy: .freeform, scale: 0.5)

        let scene = controller.canvasSceneSnapshot()

        XCTAssertNil(scene.activeMountDirective)
        XCTAssertTrue(scene.items.allSatisfy { $0.renderMode == .previewTexture })
    }
}
