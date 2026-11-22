import AppKit
import Testing
@testable import CmuxNextLayout

/// Overlay sync has any number of observers: a second subscriber must not
/// replace the first, and ending one observation keeps the others.
@MainActor @Suite struct OverlaySyncObserverTests {
    private func root() -> (LayoutRootView, StubSyncProvider) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))], activeScreenID: "s")
        let provider = StubSyncProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        return (view, provider)
    }

    @Test func twoObserversBothFireAndCancellingOneKeepsTheOther() {
        let (view, provider) = root()
        var first = 0, second = 0
        var a: LayoutOverlaySyncObservation? = view.observeOverlaySync { first += 1 }
        let b = view.observeOverlaySync { second += 1 }
        view.syncOverlay()
        #expect(first == 1 && second == 1)
        a?.cancel()
        view.syncOverlay()
        #expect(first == 1 && second == 2)
        a = nil
        withExtendedLifetime((b, provider)) {}
    }

    @Test func releasingAnObservationUnregistersIt() {
        let (view, provider) = root()
        var count = 0
        var observation: LayoutOverlaySyncObservation? = view.observeOverlaySync { count += 1 }
        view.syncOverlay()
        #expect(count == 1)
        observation = nil
        view.syncOverlay()
        #expect(count == 1)
        _ = observation
        withExtendedLifetime(provider) {}
    }
}

private final class StubSyncProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}
