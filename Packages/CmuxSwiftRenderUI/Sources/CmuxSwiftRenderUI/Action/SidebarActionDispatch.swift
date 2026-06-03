import CmuxSwiftRender
import SwiftUI

/// Injected sink that runs a sidebar button's captured ``ButtonAction``.
///
/// The interpreter and renderer stay free of cmux specifics: the host app
/// supplies a dispatch that maps an interpreted button's `ActionCommand`s onto
/// the real command surface (the cmux dispatcher), and it flows to nested
/// renderers through the SwiftUI environment via ``sidebarActionDispatch``.
///
/// ```swift
/// CustomSidebarView(fileURL: url, dataContext: ctx, dispatch: SidebarActionDispatch { action in
///     // run action.commands against the app's command dispatcher
/// })
/// ```
public struct SidebarActionDispatch: Sendable {
    /// Runs the action on the main actor when a button or tap fires.
    public let run: @MainActor @Sendable (ButtonAction) -> Void

    /// Creates a dispatch from a run closure.
    public init(run: @escaping @MainActor @Sendable (ButtonAction) -> Void) {
        self.run = run
    }

    /// A dispatch that ignores actions; the environment default.
    public static let noop = SidebarActionDispatch { _ in }
}

private struct SidebarActionDispatchKey: EnvironmentKey {
    static let defaultValue = SidebarActionDispatch.noop
}

public extension EnvironmentValues {
    /// The action sink invoked by interpreted sidebar buttons and tap gestures.
    var sidebarActionDispatch: SidebarActionDispatch {
        get { self[SidebarActionDispatchKey.self] }
        set { self[SidebarActionDispatchKey.self] = newValue }
    }
}
