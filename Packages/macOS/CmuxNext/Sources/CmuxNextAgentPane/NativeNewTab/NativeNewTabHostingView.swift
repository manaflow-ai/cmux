public import AppKit
public import SwiftUI

/// The native New Tab page in a pane tab: the SwiftUI view, plus the AppKit field the pane gives
/// the keyboard to (a focused pane makes ``fieldView`` first responder, as it does a web page's
/// field), so the keys typed after Cmd-T land in the field.
public final class NativeNewTabHostingView: NSHostingView<NativeNewTabView> {
    /// The page's text field once SwiftUI has made it; nil before the first layout.
    public var fieldView: NSView? { firstTextField(in: self) }

    /// The pane focused this view before the field existed: the field takes the keyboard as soon as
    /// it is laid out.
    override public func layout() {
        super.layout()
        if let window, window.firstResponder === self, let field = fieldView { window.makeFirstResponder(field) }
    }
}

/// The first `NSTextField` under `view`, depth first (SwiftUI's `TextField` is one on macOS).
private func firstTextField(in view: NSView) -> NSView? {
    for subview in view.subviews {
        if subview is NSTextField { return subview }
        if let found = firstTextField(in: subview) { return found }
    }
    return nil
}
