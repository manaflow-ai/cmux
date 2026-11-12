internal import AppKit
internal import ObjectiveC

/// The layer Ghostty's renderer presents into, kept so teardown can cut its
/// display callback before the renderer is freed.
///
/// On macOS, `ghostty_surface_new` makes the host view layer-hosting with
/// Ghostty's `IOSurfaceLayer` (`ghostty/src/renderer/metal/IOSurfaceLayer.zig`).
/// Its `-display` calls the renderer through two pointer-sized ivars,
/// `display_cb` and `display_ctx`, which the renderer thread sets on loop
/// entry. `ghostty_surface_free` frees the renderer but, on macOS, leaves both
/// ivars set and the layer on the view. A Core Animation commit that displays
/// the layer afterwards (a bounds change, a removal from the window) then
/// calls `drawFrame` on freed memory (#17483).
///
/// `-display` reads the ivars on the main thread, so clearing them there before
/// the native free is scheduled means no later display can reach the renderer.
///
/// `@unchecked Sendable`: the layer is only touched on the main actor; the box
/// crosses to the teardown coordinator only to be handed back to the main actor.
final class TerminalSurfaceRuntimeDisplayLayer: @unchecked Sendable {
    private static let displayCallbackIvarName = "display_cb"
    private static let displayContextIvarName = "display_ctx"

    private let layer: CALayer

    /// Captures the Ghostty layer hosted by `view`, or returns nil when the
    /// view's layer does not carry Ghostty's display-callback ivars.
    @MainActor
    init?(hostingLayerOf view: NSView) {
        guard let layer = view.layer,
              Self.pointerIvarOffset(named: Self.displayCallbackIvarName, in: layer) != nil,
              Self.pointerIvarOffset(named: Self.displayContextIvarName, in: layer) != nil else {
            return nil
        }
        self.layer = layer
    }

    /// Unbinds the layer's `-display` from the renderer. Idempotent.
    @MainActor
    func detachRendererDisplayCallback() {
        // Clear the callback first; `-display` reads it before the context.
        for name in [Self.displayCallbackIvarName, Self.displayContextIvarName] {
            guard let offset = Self.pointerIvarOffset(named: name, in: layer) else { continue }
            // The slots hold a function pointer and a renderer pointer that
            // Ghostty stores unretained, so write them as raw pointers rather
            // than through `object_setIvar`'s object semantics.
            Unmanaged.passUnretained(layer).toOpaque().storeBytes(
                of: nil as UnsafeMutableRawPointer?,
                toByteOffset: offset,
                as: UnsafeMutableRawPointer?.self
            )
        }
    }

    /// The byte offset of a pointer-sized `@` ivar Ghostty registered on the
    /// layer's class, or nil when the layer has no such ivar.
    private static func pointerIvarOffset(named name: String, in layer: CALayer) -> Int? {
        guard let layerClass = object_getClass(layer),
              let ivar = class_getInstanceVariable(layerClass, name),
              let encoding = ivar_getTypeEncoding(ivar),
              String(cString: encoding) == "@" else {
            return nil
        }
        return ivar_getOffset(ivar)
    }
}
