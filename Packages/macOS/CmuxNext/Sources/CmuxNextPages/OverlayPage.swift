public import AppKit
public import CmuxNextSettings

// COMPILE-CHECK STUB ONLY (scratch branch, never merged): the lane lead's OverlayPage stands here.
public extension PageDescriptor {
    static let overlay = PageDescriptor(id: "cmux.overlay", resource: "overlay", namespaces: ["cmux.overlay."])
}

@MainActor
public final class OverlayPage {
    public init() {}
    public static func page(route: String, in window: NSWindow, provider: any PageProvider) -> PageWebView {
        PageWebView(descriptor: .overlay, routes: [PageRoute(prefix: "cmux.overlay.", provider: provider)], route: route)!
    }
}
