import AppKit
import QuartzCore

/// The worker's connection to the window server for cross-process layer
/// sharing: wraps the private `CAContext.remoteContextWithOptions:` SPI (the
/// mechanism WebKit/Chromium use for out-of-process compositing).
///
/// This is the one non-public seam in the remote-sidebar pipeline, explicitly
/// user-authorized for this feature. The public `CARemoteLayerServer`/
/// `CARemoteLayerClient` API renders blank on current macOS (verified through
/// every documented usage variant in `docs/remote-sidebar-rendering/spike/`),
/// so the context-id route is the working substrate. The id is a plain
/// `UInt32` resolved by the window server, so no mach-port handoff is needed.
@MainActor
final class RemoteRenderContext {
    private let context: NSObject
    /// The window-server context id the host displays via `CALayerHost`.
    let contextId: UInt32

    /// Creates a remote context, or `nil` when the SPI is unavailable (the
    /// worker then simply renders nothing; the host shows its empty state).
    init?() {
        guard let contextClass = NSClassFromString("CAContext") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("remoteContextWithOptions:")
        guard contextClass.responds(to: selector),
              let unmanaged = contextClass.perform(selector, with: [:] as NSDictionary),
              let context = unmanaged.takeUnretainedValue() as? NSObject,
              let contextId = (context.value(forKey: "contextId") as? NSNumber)?.uint32Value
        else { return nil }
        self.context = context
        self.contextId = contextId
    }

    /// The root layer shared with the host (KVC onto the private context).
    var layer: CALayer? {
        get { context.value(forKey: "layer") as? CALayer }
        set { context.setValue(newValue, forKey: "layer") }
    }
}
