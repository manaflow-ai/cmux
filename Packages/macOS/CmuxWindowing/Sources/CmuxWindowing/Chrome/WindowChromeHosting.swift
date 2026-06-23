public import AppKit
public import Foundation
public import CoreGraphics

/// Two-way seam between the app-target main view (`ContentView`) and the
/// package-owned window-chrome cluster (`WindowChromeController` + the chrome
/// view structs).
///
/// The window-chrome state (titlebar text/theme generation, fullscreen flag,
/// observed window, sidebar width) and its pure logic move into
/// `WindowChromeController` in this package. Everything the chrome needs that
/// reaches LIVE app-target god state (the selected workspace title, sidebar
/// visibility, live `NSWindow` decoration installs, portal geometry sync,
/// command-palette debug sync, traffic-light inset sync) cannot move down the
/// dependency graph, so it is forwarded through this synchronous seam. The app
/// holds one conformer (a thin witness on `ContentView`) and refreshes its
/// closures each render, mirroring the `CommandPaletteFocusRestoreHost` and
/// `SelectedWorkspaceDirectoryReadingAdapter` long-lived-adapter pattern.
///
/// Isolation: `@MainActor`. Every chrome mutation originates on the main actor
/// (SwiftUI body, AppKit `WindowAccessor`, fullscreen notifications), so the
/// state lives where its callers live and the seam is a plain main-actor call,
/// not an actor hop. (Same ruling as the socket server and `CmuxSidebarGit`:
/// state lives where its callers live.)
@MainActor
public protocol WindowChromeHosting: AnyObject {
    /// Resolves the trimmed titlebar text for the currently selected workspace,
    /// or `nil` when there is no selection (the chrome then clears the text).
    func resolvedTitlebarText() -> String?

    /// Whether the left sidebar is currently visible.
    var isSidebarVisible: Bool { get }

    /// Applies live AppKit window decorations to `window` (app-side
    /// `AppDelegate.applyWindowDecorations`).
    func applyWindowDecorations(to window: NSWindow)

    /// Syncs the workspace tab-bar leading inset for the traffic lights
    /// (app-side `TabManager.syncWorkspaceTabBarLeadingInset`).
    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat)

    /// Schedules external geometry synchronization for the terminal + browser
    /// window portal registries, scoped to `window` when non-nil, else all
    /// windows.
    func schedulePortalGeometrySynchronize(for window: NSWindow?)

    /// Whether the app's background-theme logging is enabled.
    var backgroundLogEnabled: Bool { get }

    /// Emits a background-theme log line (no-op when logging is disabled).
    func logBackground(_ message: String)

    /// A short description of the current default background color + opacity for
    /// the theme-refresh log line.
    func backgroundThemeLogContext() -> String

    /// The selected workspace id, used to gate per-workspace theme refreshes.
    var selectedWorkspaceId: UUID? { get }
}
