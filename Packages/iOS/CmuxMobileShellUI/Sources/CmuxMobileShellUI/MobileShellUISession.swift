import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
#if canImport(UIKit)
import CmuxMobileTerminal
#endif
import Observation

/// One stable owner for the reference graph consumed by a mobile shell UI.
///
/// The shell composite remains the source of truth for Simulator lifecycle
/// state. This session owns the composite and the UI-local stores as one unit,
/// so SwiftUI retains one identity instead of independently pinning nested
/// reference values.
@MainActor
@Observable
public final class MobileShellUISession {
    public let store: CMUXMobileShellStore
    public let browserStore: BrowserSurfaceStore
    public let browserStreamStore: BrowserStreamStore
    #if canImport(UIKit)
    public let terminalRuntimeOwner: GhosttyRuntimeOwner
    #endif
    let startupConnectionCoordinator: MobileStartupConnectionCoordinator

    public var simulatorStreamStore: MobileSimulatorStreamStore {
        store.simulatorStreamStore
    }

    #if canImport(UIKit)
    public init(
        store: CMUXMobileShellStore,
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        browserStreamStore: BrowserStreamStore = BrowserStreamStore(),
        terminalRuntimeOwner: GhosttyRuntimeOwner
    ) {
        self.store = store
        self.browserStore = browserStore
        self.browserStreamStore = browserStreamStore
        self.terminalRuntimeOwner = terminalRuntimeOwner
        self.startupConnectionCoordinator = MobileStartupConnectionCoordinator()
    }
    #else
    public init(
        store: CMUXMobileShellStore,
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        browserStreamStore: BrowserStreamStore = BrowserStreamStore()
    ) {
        self.store = store
        self.browserStore = browserStore
        self.browserStreamStore = browserStreamStore
        self.startupConnectionCoordinator = MobileStartupConnectionCoordinator()
    }
    #endif
}
