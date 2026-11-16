public import AppKit
import CmuxNextDesign

/// Shows one of Home's sheets (Invite, Invite to Team, New Chief) over a window.
///
/// The sheet is the window's dialog overlay (``WindowOverlayHost``, as the Share dialog is), never
/// an AppKit sheet: `beginSheet` slides the sheet in from a nested modal run loop on the main thread
/// and re-renders the window's dimming mask every frame of it, so keys typed while it slid waited
/// (the user, 2026-10-29: "invite to cmux-next dialog after cmd shift p is laggy"). The overlay
/// shows in the frame of the call, fades in off the main thread (Core Animation), and its first
/// field has the keyboard when `present` returns.
///
/// ```swift
/// HomeSheetPresenter().present(HomeInviteSheet(pending: []), over: window, themeSource: page)
/// ```
@MainActor
public struct HomeSheetPresenter {
    /// A presenter; it holds no state (the sheet and the overlay host do).
    public init() {}

    /// Shows `sheet` over `window`, centered, the window dimmed and blocked until it closes.
    ///
    /// - Parameters:
    ///   - sheet: The sheet to show; its `onFinish` runs once when it closes (Cancel, Escape, a
    ///     finished action, or the window closing).
    ///   - window: The window it blocks while it shows.
    ///   - themeSource: The view whose theme scope the sheet draws in (a room's own theme); nil
    ///     draws in the window's.
    public func present(_ sheet: HomeSheetController, over window: NSWindow, themeSource: NSView? = nil) {
        let content = sheet.view
        // A room's own theme: the sheet's views resolve their colors in the page's scope.
        if let themeSource { themeSource.themeScope.fullStrength.root(content) }
        content.layoutSubtreeIfNeeded()
        content.setFrameSize(content.fittingSize)
        let handle = WindowOverlayHost.host(for: window).present(content, options: .dialog())
        sheet.dismissPresentation = { [weak handle] in handle?.dismiss() }
        handle.onDismiss = { [weak sheet] in sheet?.presentationEnded() }
        if let responder = sheet.initialResponder { content.window?.makeFirstResponder(responder) }
    }
}
