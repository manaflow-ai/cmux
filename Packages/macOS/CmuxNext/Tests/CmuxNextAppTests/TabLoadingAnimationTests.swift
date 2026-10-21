import AppKit
@testable import CmuxNextTabs
import CmuxNextDesign
import Testing

/// Debug Settings prototypes for a busy tab's indicator. Instant remains the
/// default so a release build and an untouched Debug Settings store preserve
/// the existing one-frame behavior.
@MainActor @Suite(.serialized) struct TabLoadingAnimationTests {
    @Test func debugToggleListsTheDefaultAndPrototypeVariants() throws {
        #expect(TabTunables.loadingAnimation.defaultValue == .instant)
        let descriptor = TabTunables.loadingAnimation.descriptor
        guard case .choice(let options) = descriptor.kind else {
            Issue.record("tab loading animation should be a Debug Settings choice")
            return
        }
        #expect(options.map(\.value) == TabLoadingAnimation.allCases.map(\.rawValue))
        #expect(options.map(\.title) == ["Instant", "Fade", "Fade + scale", "Fade + slide"])
    }

    @Test func instantVariantRemovesTheSpinnerAtOnce() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(TabTunables.all)
        defer { store.set(TabTunables.loadingAnimation.key, nil) }
        try #require(store.set(TabTunables.loadingAnimation.key, .choice(TabLoadingAnimation.instant.rawValue))
                     == .choice(TabLoadingAnimation.instant.rawValue))

        let cell = TabCell(item: TabItem(id: TabID("loading"), title: "Loading"))
        cell.update(item: TabItem(id: TabID("loading"), title: "Loading", isBusy: true))
        try #require(cell.spinnerLayer != nil, "busy tab should create an indicator")
        cell.update(item: TabItem(id: TabID("loading"), title: "Loading"))
        #expect(cell.spinnerLayer == nil, "instant loading transition should remove its layer")
    }

    @Test func fadeVariantKeepsTheLayerDuringItsExit() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(TabTunables.all)
        defer { store.set(TabTunables.loadingAnimation.key, nil) }
        try #require(store.set(TabTunables.loadingAnimation.key, .choice(TabLoadingAnimation.fade.rawValue))
                     == .choice(TabLoadingAnimation.fade.rawValue))
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.animationSpeed = .fast
        defer { DesignSettings.shared.animationSpeed = speed }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        guard Motion.indicators.duration(.fadeOut) > 0 else { return }

        let cell = TabCell(item: TabItem(id: TabID("loading"), title: "Loading"))
        cell.update(item: TabItem(id: TabID("loading"), title: "Loading", isBusy: true))
        try #require(cell.spinnerLayer != nil, "busy tab should create an indicator")
        cell.update(item: TabItem(id: TabID("loading"), title: "Loading"))
        #expect(cell.spinnerLayer != nil, "fade transition should retain the layer until it finishes")
        #expect(cell.isSpinnerExiting)
        #expect(cell.spinnerLayer?.layer.opacity == 0)
    }
}
