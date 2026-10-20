import QuartzCore

/// Creates the host-side layer that displays a worker's remote context:
/// a private `CALayerHost` whose `contextId` points at the worker's
/// `RemoteRenderContext`. Returns `nil` when the class is unavailable.
///
/// Counterpart of ``RemoteRenderContext``; same user-authorized private seam.
@MainActor
func makeRemoteHostedLayer(contextId: UInt32) -> CALayer? {
    guard let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else { return nil }
    let layer = hostClass.init()
    layer.setValue(NSNumber(value: contextId), forKey: "contextId")
    return layer
}
