#if canImport(AppKit)
#if DEBUG

/// One labeled "Open" button in the ``DebugWindowControlsView`` panel.
///
/// Each row pairs a stable identity, the localized button title resolved against
/// the app bundle, and a `@MainActor` action that presents one app-target debug
/// window. The debug windows are opened through app-target window controllers and
/// the app's ``DebugWindowsCoordinator`` call sites, all of which are irreducibly
/// app-coupled, so the app target snapshots the ordered button list into these
/// value rows and injects them into the package view. The package view therefore
/// holds no reference to those controllers, to ``DebugWindowsCoordinator``'s
/// app-side call sites, or to the application delegate.
///
/// The action is `@MainActor` because the legacy buttons ran their open calls
/// synchronously inside the SwiftUI button action on the main actor.
public struct DebugWindowControlAction: Identifiable {
    /// Stable identity for `ForEach`, distinct per button in the injected order.
    public let id: Int

    /// The localized button title, resolved app-side against the app bundle.
    public let title: String

    /// Presents the debug window this row opens. Invoked on the main actor when
    /// the button is pressed, matching the legacy synchronous call site.
    public let action: @MainActor () -> Void

    /// Creates one "Open" button row.
    ///
    /// - Parameters:
    ///   - id: Stable identity for `ForEach`, distinct per button.
    ///   - title: The localized button title, resolved app-side.
    ///   - action: Presents the debug window this row opens.
    public init(
        id: Int,
        title: String,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.action = action
    }
}

#endif
#endif
