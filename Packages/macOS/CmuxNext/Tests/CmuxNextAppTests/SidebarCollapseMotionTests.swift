import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar collapse prototype stays behind a Debug Settings choice so the
/// shipped transition remains the current opaque slide while the fade can be
/// compared on a running DEV/NIGHTLY build.
@MainActor @Suite(.serialized)
struct SidebarCollapseMotionTests {
    private static func withMotionOverride(_ value: TunableValue?, _ body: () throws -> Void) throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let key = SidebarTunables.collapseMotion.key
        let previous = store.override(key)
        defer { store.set(key, previous) }
        store.set(key, value)
        try body()
    }

    @Test func defaultPreservesOpaqueSlide() throws {
        try Self.withMotionOverride(nil) {
            #expect(SidebarTunables.collapseMotion.value == .slide)
            #expect(!SidebarTunables.collapseMotion.value.fadesPanel)
        }
    }

    @Test func debugChoiceEnablesSlideAndFade() throws {
        try Self.withMotionOverride(.choice(SidebarCollapseMotionVariant.slideFade.rawValue)) {
            #expect(SidebarTunables.collapseMotion.value == .slideFade)
            #expect(SidebarTunables.collapseMotion.value.fadesPanel)
        }
    }

    @Test func workspaceTitleArrivalIsInstantByDefault() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let key = SidebarTunables.workspaceTitleMotion.key
        let previous = store.override(key)
        defer { store.set(key, previous) }
        store.set(key, nil)
        #expect(SidebarTunables.workspaceTitleMotion.value == .instant)
    }
}
