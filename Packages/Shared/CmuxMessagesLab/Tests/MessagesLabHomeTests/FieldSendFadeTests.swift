import AppKit
import QuartzCore
import Testing
@testable import MessagesLabHome

/// The message box's send fade: a Core Animation opacity pulse on the field's
/// glass container and its key-window rims, run by the render server (no display link wakes the
/// main thread), and gated by the host's motion switch: off, nothing animates and the field keeps
/// its model opacity in the same frame.
@MainActor @Suite(.serialized) struct FieldSendFadeTests {
    private func makeChrome(animates: Bool) -> FieldChrome {
        let chrome = FieldChrome(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        chrome.wantsLayer = true
        chrome.fieldContainer.wantsLayer = true
        chrome.animatesFade = { animates }
        return chrome
    }

    private func fadeLayers(_ chrome: FieldChrome) throws -> [CALayer] {
        try [#require(chrome.fieldContainer.layer)] + chrome.keyFix.field.layers
    }

    private func opacityAnimations(_ layer: CALayer) -> [CAKeyframeAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CAKeyframeAnimation }
            .filter { $0.keyPath == "opacity" }
    }

    @Test func theSendFadeIsOneRenderServerOpacityAnimationPerLayer() throws {
        let chrome = makeChrome(animates: true)
        let begin = CACurrentMediaTime()
        chrome.sendPulse(begin: begin)
        for layer in try fadeLayers(chrome) {
            let fades = opacityAnimations(layer)
            #expect(fades.count == 1)
            #expect(fades.first?.beginTime == begin)
            // The pulse dips and comes back to the model opacity.
            let values = (fades.first?.values as? [NSNumber])?.map(\.doubleValue) ?? []
            #expect(values.contains { $0 < 1 })
            #expect(abs((values.last ?? 0) - 1) < 0.01)
            #expect(layer.opacity == 1)
        }
    }

    @Test func motionOffAppliesAtOnce() throws {
        let chrome = makeChrome(animates: false)
        chrome.sendPulse(begin: CACurrentMediaTime())
        for layer in try fadeLayers(chrome) {
            #expect(opacityAnimations(layer).isEmpty)
            #expect(layer.opacity == 1)
        }
        #expect(chrome.fieldContainer.alphaValue == 1)
    }

    @Test func theViewsGateReachesItsMessageBox() async throws {
        let rig = try await HomeChatRig(history: 4)
        defer { rig.stop() }
        let chrome = rig.view.controller.host.fieldChrome
        chrome.fieldContainer.wantsLayer = true
        // Standalone MessagesLab fades, as Messages does.
        #expect(rig.view.fadeMotionGate())
        rig.view.fadeMotionGate = { false }
        chrome.sendPulse(begin: CACurrentMediaTime())
        for layer in try fadeLayers(chrome) { #expect(opacityAnimations(layer).isEmpty) }
        rig.view.fadeMotionGate = { true }
        chrome.sendPulse(begin: CACurrentMediaTime())
        for layer in try fadeLayers(chrome) { #expect(opacityAnimations(layer).count == 1) }
    }
}
