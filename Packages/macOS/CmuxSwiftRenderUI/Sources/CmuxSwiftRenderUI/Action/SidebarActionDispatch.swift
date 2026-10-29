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

    /// Writes plain text to the system clipboard for a JS sidebar's
    /// `clipboard.write(text)`, or `nil` when the host offers no clipboard.
    ///
    /// The runtime calls it only while it is dispatching a user gesture and
    /// only with text inside its size cap; hosts just perform the write.
    public let writeClipboard: (@MainActor @Sendable (String) -> Void)?

    /// Creates a dispatch from a run closure and an optional clipboard writer.
    ///
    /// - Parameters:
    ///   - run: Runs captured button and tap actions.
    ///   - writeClipboard: Writes gesture-approved plain text to the system
    ///     clipboard. Defaults to `nil`, which makes `clipboard.write` reject
    ///     every call (hosts such as the out-of-process renderer have no
    ///     clipboard to offer).
    public init(
        run: @escaping @MainActor @Sendable (ButtonAction) -> Void,
        writeClipboard: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.run = run
        self.writeClipboard = writeClipboard
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
