import AppKit
import ObjectiveC

/// Counts the frames a fake Ghostty renderer was asked to draw.
final class FakeGhosttyRenderer {
    var displayCount = 0
}

/// A stand-in for the `IOSurfaceLayer` that GhosttyKit installs as the host
/// view's layer on macOS (`ghostty/src/renderer/metal/IOSurfaceLayer.zig`).
///
/// Ghostty registers the class at runtime as a `CALayer` subclass with two
/// pointer-sized `@` ivars, `display_cb` and `display_ctx`, and a `-display`
/// that calls `display_cb(display_ctx)`. The renderer thread points them at
/// `drawFrame` and the renderer on loop entry. This fake registers the same
/// shape, so a test can observe whether a Core Animation display of the layer
/// still reaches the renderer.
@MainActor
enum FakeGhosttyIOSurfaceLayer {
    private nonisolated static let className = "CmuxTestGhosttyIOSurfaceLayer"

    /// Makes a layer whose display callback draws through `renderer`, the way
    /// Ghostty's renderer loop entry binds it.
    static func make(renderer: FakeGhosttyRenderer) -> CALayer {
        let layerClass = registeredClass()
        guard let layer = (layerClass as? NSObject.Type)?.init() as? CALayer else {
            preconditionFailure("\(className) must instantiate as a CALayer")
        }
        storePointer(
            unsafeBitCast(displayCallback, to: UnsafeMutableRawPointer.self),
            ivarNamed: "display_cb",
            in: layer
        )
        storePointer(
            Unmanaged.passUnretained(renderer).toOpaque(),
            ivarNamed: "display_ctx",
            in: layer
        )
        return layer
    }

    /// The layer's current display callback, or nil once it is detached.
    /// Nonisolated so a native-free override can sample it off the main
    /// thread, after teardown's main-actor work has happened-before the free.
    nonisolated static func displayCallbackPointer(of layer: CALayer) -> UnsafeMutableRawPointer? {
        loadPointer(ivarNamed: "display_cb", in: layer)
    }

    /// The layer's current display context (the renderer), or nil once it is
    /// detached.
    nonisolated static func displayContextPointer(of layer: CALayer) -> UnsafeMutableRawPointer? {
        loadPointer(ivarNamed: "display_ctx", in: layer)
    }

    private typealias DisplayCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private nonisolated static var displayCallback: DisplayCallback {
        { context in
            guard let context else { return }
            Unmanaged<FakeGhosttyRenderer>.fromOpaque(context)
                .takeUnretainedValue()
                .displayCount += 1
        }
    }

    private static func registeredClass() -> AnyClass {
        if let existing = NSClassFromString(className) {
            return existing
        }
        guard let layerClass = objc_allocateClassPair(CALayer.self, className, 0) else {
            preconditionFailure("could not allocate \(className)")
        }
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        let pointerAlignmentLog2 = UInt8(
            MemoryLayout<UnsafeMutableRawPointer>.alignment.trailingZeroBitCount
        )
        for name in ["display_cb", "display_ctx"] {
            guard class_addIvar(layerClass, name, pointerSize, pointerAlignmentLog2, "@") else {
                preconditionFailure("could not add \(name) to \(className)")
            }
        }
        let display: @convention(block) (CALayer) -> Void = { layer in
            guard let callback = loadPointer(ivarNamed: "display_cb", in: layer) else { return }
            unsafeBitCast(callback, to: DisplayCallback.self)(
                loadPointer(ivarNamed: "display_ctx", in: layer)
            )
        }
        class_addMethod(
            layerClass,
            #selector(CALayer.display),
            imp_implementationWithBlock(unsafeBitCast(display, to: AnyObject.self)),
            "v@:"
        )
        objc_registerClassPair(layerClass)
        return layerClass
    }

    private nonisolated static func ivarOffset(named name: String, in layer: CALayer) -> Int {
        guard let layerClass = object_getClass(layer),
              let ivar = class_getInstanceVariable(layerClass, name) else {
            preconditionFailure("\(className) is missing \(name)")
        }
        return ivar_getOffset(ivar)
    }

    private nonisolated static func storePointer(
        _ pointer: UnsafeMutableRawPointer?,
        ivarNamed name: String,
        in layer: CALayer
    ) {
        Unmanaged.passUnretained(layer).toOpaque().storeBytes(
            of: pointer,
            toByteOffset: ivarOffset(named: name, in: layer),
            as: UnsafeMutableRawPointer?.self
        )
    }

    private nonisolated static func loadPointer(
        ivarNamed name: String,
        in layer: CALayer
    ) -> UnsafeMutableRawPointer? {
        Unmanaged.passUnretained(layer).toOpaque().load(
            fromByteOffset: ivarOffset(named: name, in: layer),
            as: UnsafeMutableRawPointer?.self
        )
    }
}
