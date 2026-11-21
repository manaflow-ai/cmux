#if DEBUG
public import AppKit
import SwiftUI

/// DEBUG ONLY: Debug > Chief Without Home Prototype (Lawrence, 2026-11-20: "i want to see prototype of the what
/// david is talking about, wehre we get rid of home, and chiefs/other stuff is kinda integrated together"). One
/// window that lays out cmux three ways with no Home (``ChiefNoHomeVariant``), switched in its bar, in the app's
/// appearance. The labels and data are DEV-only English.
@MainActor
public final class ChiefNoHomePlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.chiefNoHomePlayground")

    private let window: NSWindow
    private let model = ChiefNoHomePlaygroundModel()

    /// Shows the prototype (one window: a second call brings it front) on `variant` (1...3; nil keeps the shown one).
    public static func show(variant: Int? = nil) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? ChiefNoHomePlaygroundContainer)?.owner as? ChiefNoHomePlayground ?? ChiefNoHomePlayground()
        if let picked = variant.flatMap(ChiefNoHomeVariant.init(rawValue:)) { playground.model.variant = picked }
        playground.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.identifier = Self.identifier
        window.title = "Chief Without Home Prototype"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let container = ChiefNoHomePlaygroundContainer()
        container.owner = self
        let hosting = NSHostingView(rootView: ChiefNoHomePlaygroundView(model: model))
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        hosting.frame = container.bounds
        window.center()
    }

    public func windowWillClose(_ notification: Notification) {
        // The window lets go of the playground; nothing else holds it.
        (window.contentView as? ChiefNoHomePlaygroundContainer)?.owner = nil
    }
}
#endif
