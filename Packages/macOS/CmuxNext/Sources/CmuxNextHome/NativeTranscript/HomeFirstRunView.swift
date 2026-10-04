import AppKit

/// The empty Chief conversation's first-run panel.
final class HomeFirstRunView: NSView {
    let title = NSTextField(labelWithString: "")
    let suggestion = NSButton(title: "", target: nil, action: nil)
}
