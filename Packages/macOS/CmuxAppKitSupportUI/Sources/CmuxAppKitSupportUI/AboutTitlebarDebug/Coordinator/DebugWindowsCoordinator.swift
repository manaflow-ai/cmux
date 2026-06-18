#if canImport(AppKit)

import AppKit
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
    private var aboutTitlebarController: AboutTitlebarDebugWindowController?

    /// Creates the coordinator.
    ///
    /// - Parameter decorator: The window-decoration seam. Held weakly because the
    ///   app-side conformer (`AppDelegate`) is a singleton that also owns this
    ///   coordinator.
    public init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
        self.aboutTitlebarStore = AboutTitlebarDebugStore(decorator: decorator)
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
}

#endif
