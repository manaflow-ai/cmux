#if canImport(AppKit)

public import AppKit
public import Observation

/// Owns and sequences the About Titlebar Debug subsystem on behalf of the app.
///
/// The app composition root constructs one coordinator, injecting the
/// ``WindowDecorating`` seam, and forwards its existing call sites (the Debug
/// menu, the `About`/`Acknowledgments` window controllers, and "open all debug
/// windows") into this type. The coordinator owns the ``AboutTitlebarDebugStore``
/// and lazily owns the editor window controller, so the app target no longer
/// declares the underlying types.
@MainActor
@Observable
public final class DebugWindowsCoordinator {
    /// The store backing the About Titlebar Debug options. Exposed so the app's
    /// `About`/`Acknowledgments` window controllers can apply current options to
    /// their windows as they build them.
    public let aboutTitlebarStore: AboutTitlebarDebugStore

    @ObservationIgnored
    private weak var decorator: (any WindowDecorating)?

    @ObservationIgnored
    private weak var browserDebugContext: (any BrowserDebugContext)?

    @ObservationIgnored
    private var aboutTitlebarController: AboutTitlebarDebugWindowController?

    @ObservationIgnored
    private var browserImportHintController: BrowserImportHintDebugWindowController?

    @ObservationIgnored
    private var browserProfilePopoverController: BrowserProfilePopoverDebugWindowController?

    #if DEBUG
    @ObservationIgnored
    private var splitButtonLayoutController: SplitButtonLayoutDebugWindowController?

    @ObservationIgnored
    private var debugWindowControlsController: DebugWindowControlsWindowController?

    @ObservationIgnored
    private let debugWindowControlsContentProvider: (@MainActor () -> NSView)?

    @ObservationIgnored
    private var menuBarExtraDebugController: MenuBarExtraDebugWindowController?

    @ObservationIgnored
    private let menuBarExtraDebugContentProvider: (@MainActor () -> NSView)?

    @ObservationIgnored
    private var backgroundDebugController: BackgroundDebugWindowController?

    @ObservationIgnored
    private let backgroundDebugContentProvider: (@MainActor () -> NSView)?
    #endif

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - decorator: The window-decoration seam. Held weakly because the
    ///     app-side conformer (`AppDelegate`) is a singleton that also owns this
    ///     coordinator.
    ///   - browserDebugContext: The browser-debug action seam. Held weakly for the
    ///     same reason as `decorator`. Backs the import-hint panel's quick-action
    ///     buttons. `nil` makes those buttons no-ops.
    ///   - debugWindowControlsContentProvider: Builds the content view for the
    ///     "Debug Window Controls" panel (DEBUG only). The panel's SwiftUI content
    ///     is app-coupled (it opens other app-target debug windows and reads
    ///     app-target settings), so the app target injects it here. `nil` disables
    ///     ``showDebugWindowControls()`` (no panel is presented).
    ///   - menuBarExtraDebugContentProvider: Builds the content view for the "Menu
    ///     Bar Extra Debug" panel (DEBUG only). The panel reads the app-target
    ///     `MenuBarIconDebugSettings` defaults and refreshes the live menu-bar icon,
    ///     so the app target injects it here. `nil` disables
    ///     ``showMenuBarExtraDebug()`` (no panel is presented).
    ///   - backgroundDebugContentProvider: Builds the content view for the
    ///     "Background Debug" panel (DEBUG only). The panel drives the live
    ///     main-window glass tint through the app-target window-chrome composition,
    ///     so the app target injects it here. `nil` disables
    ///     ``showBackgroundDebug()`` (no panel is presented).
    public init(
        decorator: (any WindowDecorating)?,
        browserDebugContext: (any BrowserDebugContext)? = nil,
        debugWindowControlsContentProvider: (@MainActor () -> NSView)? = nil,
        menuBarExtraDebugContentProvider: (@MainActor () -> NSView)? = nil,
        backgroundDebugContentProvider: (@MainActor () -> NSView)? = nil
    ) {
        self.decorator = decorator
        self.browserDebugContext = browserDebugContext
        self.aboutTitlebarStore = AboutTitlebarDebugStore(decorator: decorator)
        #if DEBUG
        self.debugWindowControlsContentProvider = debugWindowControlsContentProvider
        self.menuBarExtraDebugContentProvider = menuBarExtraDebugContentProvider
        self.backgroundDebugContentProvider = backgroundDebugContentProvider
        #else
        _ = debugWindowControlsContentProvider
        _ = menuBarExtraDebugContentProvider
        _ = backgroundDebugContentProvider
        #endif
    }

    /// Presents the About Titlebar Debug editor, creating its window on first use.
    public func showAboutTitlebarDebugWindow() {
        let controller = aboutTitlebarController ?? AboutTitlebarDebugWindowController(
            store: aboutTitlebarStore,
            decorator: decorator
        )
        aboutTitlebarController = controller
        controller.show()
    }

    /// Presents the Browser Import Hint debug panel, creating its window on first
    /// use.
    public func showBrowserImportHintDebug() {
        let controller = browserImportHintController
            ?? BrowserImportHintDebugWindowController(
                decorator: decorator,
                context: browserDebugContext
            )
        browserImportHintController = controller
        controller.show()
    }

    /// Presents the Browser Profile Popover debug panel, creating its window on
    /// first use.
    public func showBrowserProfilePopoverDebug() {
        let controller = browserProfilePopoverController
            ?? BrowserProfilePopoverDebugWindowController(decorator: decorator)
        browserProfilePopoverController = controller
        controller.show()
    }

    #if DEBUG
    /// Presents the Split Button Layout debug editor, creating its window on
    /// first use.
    public func showSplitButtonLayoutDebugWindow() {
        let controller = splitButtonLayoutController
            ?? SplitButtonLayoutDebugWindowController(decorator: decorator)
        splitButtonLayoutController = controller
        controller.show()
    }

    /// Presents the Debug Window Controls panel, creating its window on first use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showDebugWindowControls() {
        guard let debugWindowControlsContentProvider else { return }
        let controller = debugWindowControlsController
            ?? DebugWindowControlsWindowController(
                decorator: decorator,
                contentProvider: debugWindowControlsContentProvider
            )
        debugWindowControlsController = controller
        controller.show()
    }

    /// Presents the Menu Bar Extra Debug panel, creating its window on first use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showMenuBarExtraDebug() {
        guard let menuBarExtraDebugContentProvider else { return }
        let controller = menuBarExtraDebugController
            ?? MenuBarExtraDebugWindowController(
                decorator: decorator,
                contentProvider: menuBarExtraDebugContentProvider
            )
        menuBarExtraDebugController = controller
        controller.show()
    }

    /// Presents the Background Debug panel, creating its window on first use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showBackgroundDebug() {
        guard let backgroundDebugContentProvider else { return }
        let controller = backgroundDebugController
            ?? BackgroundDebugWindowController(
                decorator: decorator,
                contentProvider: backgroundDebugContentProvider
            )
        backgroundDebugController = controller
        controller.show()
    }
    #endif
}

#endif
