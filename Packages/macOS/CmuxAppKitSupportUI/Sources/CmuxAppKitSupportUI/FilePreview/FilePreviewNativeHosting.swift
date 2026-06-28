public import AppKit
public import Foundation
public import SwiftUI
public import CmuxFoundation

/// Seam between ``FilePreviewPDFContainerView`` (which lives in this package) and
/// the app-side file-preview panel that owns it.
///
/// The container drives focus-endpoint registration, preferred focus-intent
/// notes, keyboard-focus resync after a first-responder change, and the localized
/// "Open with…" chrome menu through this protocol so the panel, the app's
/// `AppDelegate`, and the localized `FileExternalOpenMenu` all stay in the
/// executable app target. The host (the panel) is injected after construction via
/// ``FilePreviewPDFContainerView/setHost(_:)``.
@MainActor
public protocol FilePreviewNativeHosting: AnyObject {
    /// Registers a focusable preview region (PDF canvas, thumbnails, outline) so
    /// the host's focus coordinator can route first-responder focus to it.
    func attachPreviewFocus(
        root: NSView,
        primaryResponder: NSView,
        intent: FilePreviewPanelFocusIntent
    )

    /// Records the preview region the user most recently interacted with as the
    /// host's preferred focus intent.
    func noteFilePreviewFocusIntent(_ intent: FilePreviewPanelFocusIntent)

    /// Returns the preview region that currently owns first responder in `window`,
    /// or `nil` when no registered region is focused.
    func currentFilePreviewFocusIntent(in window: NSWindow?) -> FilePreviewPanelFocusIntent?

    /// Resyncs cmux keyboard focus after the first responder changes inside the
    /// preview; the host forwards to the app's `AppDelegate`.
    func syncKeyboardFocusAfterFirstResponderChange(in window: NSWindow?)

    /// Builds the localized "Open with…" chrome menu for `url`. The localized
    /// `FileExternalOpenMenu` view stays app-side, so the container reaches it
    /// through the host.
    func makeFileOpenChromeMenu(for url: URL) -> AnyView
}
