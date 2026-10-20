public import AppKit

/// Red stub: the floating Add Server card (AddServerCardTests fail).
@MainActor
public final class AddServerCardPanel: NSPanel {
    public static let topInset: CGFloat = 0

    public init(model: ServerModel) {
        super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    public func present(over window: NSWindow?, takeKeys: Bool) {}

    public static func placement(size: CGSize, over parent: NSRect?, in visible: NSRect) -> NSRect { .zero }
}
