import AppKit

/// Captures the hosting view behind an extension toolbar button so its popover
/// can anchor to the correct AppKit view.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionAnchorViewHolder {
    weak var view: NSView?
}
