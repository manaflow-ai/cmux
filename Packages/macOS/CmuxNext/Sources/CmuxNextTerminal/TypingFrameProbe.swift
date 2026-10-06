import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// Marks ``TypingLatencyProbe/Mark/contents`` when Ghostty hands a finished
/// frame to its `IOSurfaceLayer` (`setContents:` on the main thread; Core
/// Animation commits it at the end of that run-loop turn). Installed only
/// while the probe is enabled: it adds a `setContents:` override to the
/// layer's runtime class that calls `CALayer`'s and then marks.
enum TypingFrameProbe {
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    @MainActor private static var installed: Set<ObjectIdentifier> = []

    @MainActor static func install(on layer: CALayer) {
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self, installed.insert(ObjectIdentifier(layerClass)).inserted else { return }
        let selector = #selector(setter: CALayer.contents)
        guard let inherited = class_getInstanceMethod(CALayer.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(inherited), to: SetContents.self)
        let override: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in
            original(layer, selector, contents)
            TypingLatencyProbe.shared.mark(.contents)
        }
        class_addMethod(layerClass, selector, imp_implementationWithBlock(override), method_getTypeEncoding(inherited))
    }
}
