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
    private let aboutPanelStrings: AboutPanelStrings

    @ObservationIgnored
    private let acknowledgmentsStrings: AcknowledgmentsStrings

    @ObservationIgnored
    private var aboutController: AboutWindowController?

    @ObservationIgnored
    private var acknowledgmentsController: AcknowledgmentsWindowController?

    @ObservationIgnored
    private var aboutTitlebarController: AboutTitlebarDebugWindowController?

    @ObservationIgnored
    private var browserImportHintController: BrowserImportHintDebugWindowController?

    @ObservationIgnored
    private var browserProfilePopoverController: BrowserProfilePopoverDebugWindowController?

    @ObservationIgnored
    private var tabBarBackdropLabController: TabBarBackdropLabWindowController?

    @ObservationIgnored
    private let tabBarBackdropLabContentProvider: (@MainActor () -> NSView)?

    @ObservationIgnored
    private var sidebarDebugController: SidebarDebugWindowController?

    @ObservationIgnored
    private let sidebarDebugContentProvider: (@MainActor () -> NSView)?

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
    private let menuBarExtraDebugRefresh: (@MainActor () -> Void)?

    @ObservationIgnored
    private var backgroundDebugController: BackgroundDebugWindowController?

    @ObservationIgnored
    private let backgroundDebugContentProvider: (@MainActor () -> NSView)?

    @ObservationIgnored
    private var fileExplorerStyleDebugController: FileExplorerStyleDebugWindowController?

    @ObservationIgnored
    private let fileExplorerStyleDebugContentProvider: (@MainActor () -> NSView)?
    #endif

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - decorator: The window-decoration seam. Held weakly because the
    ///     app-side conformer (`AppDelegate`) is a singleton that also owns this
    ///     coordinator.
    ///   - aboutPanelStrings: Localized labels for the About window, resolved
    ///     app-side against the app bundle's catalog.
    ///   - acknowledgmentsStrings: Localized title and fallback text for the
    ///     Acknowledgments window, resolved app-side against the app bundle's
    ///     catalog.
    ///   - browserDebugContext: The browser-debug action seam. Held weakly for the
    ///     same reason as `decorator`. Backs the import-hint panel's quick-action
    ///     buttons. `nil` makes those buttons no-ops.
    ///   - debugWindowControlsContentProvider: Builds the content view for the
    ///     "Debug Window Controls" panel (DEBUG only). The panel's SwiftUI content
    ///     is app-coupled (it opens other app-target debug windows and reads
    ///     app-target settings), so the app target injects it here. `nil` disables
    ///     ``showDebugWindowControls()`` (no panel is presented).
    ///   - menuBarExtraDebugRefresh: Redraws the live menu-bar icon after a tuning
    ///     change in the "Menu Bar Extra Debug" panel (DEBUG only). The panel and
    ///     its ``MenuBarIconDebugSettings`` defaults are package-owned, but the live
    ///     icon refresh is app-coupled, so the app target injects it here. `nil`
    ///     disables ``showMenuBarExtraDebug()`` (no panel is presented).
    ///   - backgroundDebugContentProvider: Builds the content view for the
    ///     "Background Debug" panel (DEBUG only). The panel drives the live
    ///     main-window glass tint through the app-target window-chrome composition,
    ///     so the app target injects it here. `nil` disables
    ///     ``showBackgroundDebug()`` (no panel is presented).
    ///   - tabBarBackdropLabContentProvider: Builds the content view for the "Tab
    ///     Bar Backdrop Lab" panel. The lab renders live `Bonsplit` tab bars and
    ///     samples the app-target `GhosttyApp`/`Workspace` backdrop tuning, so the
    ///     app target injects it here. `nil` disables ``showTabBarBackdropLab()``
    ///     (no panel is presented).
    ///   - sidebarDebugContentProvider: Builds the content view for the "Sidebar
    ///     Debug" panel. The editor resolves the live app accent color and the
    ///     localized active-indicator display names against the app bundle, so the
    ///     app target injects it here. `nil` disables ``showSidebarDebug()`` (no
    ///     panel is presented).
    ///   - fileExplorerStyleDebugContentProvider: Builds the content view for the
    ///     "File Explorer Style Debug" panel (DEBUG only). The panel reads and
    ///     writes the app-target `FileExplorerStyle` enum and posts the app-owned
    ///     `fileExplorerStyleDidChange` notification, so the app target injects it
    ///     here. `nil` disables ``showFileExplorerStyleDebug()`` (no panel is
    ///     presented).
    public init(
        decorator: (any WindowDecorating)?,
        aboutPanelStrings: AboutPanelStrings,
        acknowledgmentsStrings: AcknowledgmentsStrings,
        browserDebugContext: (any BrowserDebugContext)? = nil,
        tabBarBackdropLabContentProvider: (@MainActor () -> NSView)? = nil,
        sidebarDebugContentProvider: (@MainActor () -> NSView)? = nil,
        debugWindowControlsContentProvider: (@MainActor () -> NSView)? = nil,
        menuBarExtraDebugRefresh: (@MainActor () -> Void)? = nil,
        backgroundDebugContentProvider: (@MainActor () -> NSView)? = nil,
        fileExplorerStyleDebugContentProvider: (@MainActor () -> NSView)? = nil
    ) {
        self.decorator = decorator
        self.aboutPanelStrings = aboutPanelStrings
        self.acknowledgmentsStrings = acknowledgmentsStrings
        self.browserDebugContext = browserDebugContext
        self.aboutTitlebarStore = AboutTitlebarDebugStore(decorator: decorator)
        self.tabBarBackdropLabContentProvider = tabBarBackdropLabContentProvider
        self.sidebarDebugContentProvider = sidebarDebugContentProvider
        #if DEBUG
        self.debugWindowControlsContentProvider = debugWindowControlsContentProvider
        self.menuBarExtraDebugRefresh = menuBarExtraDebugRefresh
        self.backgroundDebugContentProvider = backgroundDebugContentProvider
        self.fileExplorerStyleDebugContentProvider = fileExplorerStyleDebugContentProvider
        #else
        _ = debugWindowControlsContentProvider
        _ = menuBarExtraDebugRefresh
        _ = backgroundDebugContentProvider
        _ = fileExplorerStyleDebugContentProvider
        #endif
    }

    /// Presents the "About cmux" window, creating it on first use.
    ///
    /// Replaces the former `AboutWindowController.shared` singleton: the
    /// coordinator owns the controller's lifecycle and injects the
    /// ``AboutTitlebarDebugStore``, the ``WindowDecorating`` seam, the localized
    /// strings, and the closure that opens the Acknowledgments window.
    public func showAbout() {
        let controller = aboutController ?? AboutWindowController(
            store: aboutTitlebarStore,
            decorator: decorator,
            strings: aboutPanelStrings,
            showAcknowledgments: { [weak self] in self?.showAcknowledgments() }
        )
        aboutController = controller
        controller.show()
    }

    /// Presents the Acknowledgments (Third-Party Licenses) window, creating it on
    /// first use.
    ///
    /// Replaces the former `AcknowledgmentsWindowController.shared` singleton.
    public func showAcknowledgments() {
        let controller = acknowledgmentsController ?? AcknowledgmentsWindowController(
            strings: acknowledgmentsStrings
        )
        acknowledgmentsController = controller
        controller.show()
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

    /// Presents the Tab Bar Backdrop Lab panel, creating its window on first use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showTabBarBackdropLab() {
        guard let tabBarBackdropLabContentProvider else { return }
        let controller = tabBarBackdropLabController
            ?? TabBarBackdropLabWindowController(
                contentProvider: tabBarBackdropLabContentProvider
            )
        tabBarBackdropLabController = controller
        controller.show()
    }

    /// Presents the Sidebar Debug editor, creating its window on first use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showSidebarDebug() {
        guard let sidebarDebugContentProvider else { return }
        let controller = sidebarDebugController
            ?? SidebarDebugWindowController(
                decorator: decorator,
                contentProvider: sidebarDebugContentProvider
            )
        sidebarDebugController = controller
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
        guard let menuBarExtraDebugRefresh else { return }
        let controller = menuBarExtraDebugController
            ?? MenuBarExtraDebugWindowController(
                decorator: decorator,
                refreshMenuBarIcon: menuBarExtraDebugRefresh
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

    /// Presents the File Explorer Style debug panel, creating its window on first
    /// use.
    ///
    /// No-op when no content provider was injected at construction.
    public func showFileExplorerStyleDebug() {
        guard let fileExplorerStyleDebugContentProvider else { return }
        let controller = fileExplorerStyleDebugController
            ?? FileExplorerStyleDebugWindowController(
                decorator: decorator,
                contentProvider: fileExplorerStyleDebugContentProvider
            )
        fileExplorerStyleDebugController = controller
        controller.show()
    }
    #endif
}

#endif
