public import AppKit
public import SwiftUI

/// A SwiftUI-owned AppKit insertion point for native WebKit portal hosting.
///
/// Browser portals must be descendants of the SwiftUI content hierarchy on
/// macOS 27 so native pointer movement reaches WebKit. The host is supplied by
/// `NSViewRepresentable`, which keeps AppKit portal children out of the
/// `NSHostingView` view tree itself.
@MainActor
public final class WindowContentOverlayBrowserHostView: NSView {
    public static let identifier = NSUserInterfaceItemIdentifier("cmux.windowContentOverlay.browserHost")

    override public var isOpaque: Bool { false }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Mounts the browser portal host inside SwiftUI's managed content hierarchy.
public struct WindowContentOverlayBrowserHost: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowContentOverlayBrowserHostView {
        WindowContentOverlayBrowserHostView(frame: .zero)
    }

    public func updateNSView(_ nsView: WindowContentOverlayBrowserHostView, context: Context) {}
}
