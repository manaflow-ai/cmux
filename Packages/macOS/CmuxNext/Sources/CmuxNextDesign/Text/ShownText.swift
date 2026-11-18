public import AppKit

/// A view that shows a line of text: a stock `NSTextField` or a ``ChromeLabel``.
public protocol ShownText: NSView {
    var stringValue: String { get set }
    var textColor: NSColor? { get set }
    var font: NSFont? { get set }
}

extension NSTextField: ShownText {}
extension ChromeLabel: ShownText {}
