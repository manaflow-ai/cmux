public import AppKit

/// Paste and Match Style (Cmd-Shift-V, `pasteAsPlainText:`) for a Chromium page.
///
/// AppKit's text views answer `pasteAsPlainText:`; Chromium's page view
/// (`RenderWidgetHostViewCocoa`) answers only `pasteAndMatchStyle:`, the
/// selector Chrome's own Edit menu sends for Cmd-Shift-V. Without this route the
/// menu item finds no target while a Chromium page has the keyboard, so it is
/// disabled and the chord does nothing (#27619). The app resolves every
/// nil-targeted paste action through its key router's paste target.
@MainActor
public struct ChromiumPasteAndMatchStyleRoute {
    static let action = #selector(NSTextView.pasteAsPlainText(_:))
    /// Chrome's selector (`-[RenderWidgetHostViewCocoa pasteAndMatchStyle:]`).
    static let chromiumAction = Selector(("pasteAndMatchStyle:"))

    public init() {}

    /// A forwarder to the key window's first responder when it answers only
    /// Chrome's selector, or nil to keep AppKit's target `found`.
    public func target(for action: Selector, found: AnyObject?, in window: NSWindow?) -> AnyObject? {
        guard action == Self.action, found == nil, let responder = window?.firstResponder,
              responder.responds(to: Self.chromiumAction) else { return nil }
        return ChromiumPasteAndMatchStyleForwarder(responder: responder)
    }
}

/// Sends Chrome's `pasteAndMatchStyle:` to the page view for AppKit's
/// `pasteAsPlainText:`. The menu item takes the page view's own validation of
/// Chrome's selector, so it is disabled where Chrome disables it.
@MainActor
final class ChromiumPasteAndMatchStyleForwarder: NSObject, NSMenuItemValidation {
    private weak var responder: NSResponder?

    init(responder: NSResponder) {
        self.responder = responder
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        _ = responder?.tryToPerform(ChromiumPasteAndMatchStyleRoute.chromiumAction, with: sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let responder, (responder as? NSView)?.window != nil else { return false }
        guard let validator = responder as? any NSUserInterfaceValidations else { return true }
        let probe = NSMenuItem(title: item.title, action: ChromiumPasteAndMatchStyleRoute.chromiumAction, keyEquivalent: "")
        return validator.validateUserInterfaceItem(probe)
    }
}
