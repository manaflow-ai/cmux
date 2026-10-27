import CoreGraphics
@testable import CmuxNextTerminal
import ObjectiveC
import QuartzCore
import Testing

/// TypingFrameProbe's `setContents:` override calls its superclass's IMP as it is at the call, so a hook
/// another tool puts on the superclass later (RenderStats, while armed) runs while it is in and never after.
@MainActor @Suite(.serialized, .enabled(if: TypingFrameProbe.hooksEveryLayer, "renderer-owned frames set no layer contents"))
struct TypingFrameProbeTests {
    nonisolated class HookedBaseLayer: CALayer {}
    nonisolated final class ProbedLayer: HookedBaseLayer {}

    final class Calls {
        var count = 0
    }

    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    @Test func theOverrideCallsTheSuperclassIMPOfTheCall() throws {
        let selector = #selector(setter: CALayer.contents)
        let layer = ProbedLayer()
        TypingFrameProbe.install(on: layer, gate: TerminalContentsGate())
        let root = try #require(class_getInstanceMethod(CALayer.self, selector))
        let rootIMP = method_getImplementation(root)
        let forward = unsafeBitCast(rootIMP, to: SetContents.self)
        let calls = Calls()
        let hook: @convention(block) (AnyObject, AnyObject?) -> Void = { object, contents in
            calls.count += 1
            forward(object, selector, contents)
        }
        // A hook on the superclass after the install: the probe's calls run it.
        #expect(class_addMethod(HookedBaseLayer.self, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(root)))
        let first = try #require(Self.image(gray: 0))
        layer.contents = first
        #expect(calls.count == 1)
        #expect(layer.contents.map { $0 as AnyObject } === first)
        // The hook taken out (CALayer's IMP back): the probe's calls skip it.
        let base = try #require(class_getInstanceMethod(HookedBaseLayer.self, selector))
        method_setImplementation(base, rootIMP)
        let second = try #require(Self.image(gray: 1))
        layer.contents = second
        #expect(calls.count == 1)
        #expect(layer.contents.map { $0 as AnyObject } === second)
    }

    private static func image(gray: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }
}
