import CmuxConversationCore
@testable import CmuxConversationGeometry
import Foundation
import QuartzCore
import Testing

/// Effect glyphs that are not rendered yet render away from the main thread
/// and show when ready: a row scrolled on screen before the transcript's
/// prefetch had rendered its long effect run stopped the main thread for
/// 597 ms on the phone, typesetting the whole string once per letter.
@MainActor
@Suite struct ConversationTextEffectRenderAheadTests {
    private func effectText(_ string: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: ConversationPlatformFont.systemFont(ofSize: 17),
            .foregroundColor: ConversationPlatformColor.clear,
        ])
        let whole = NSRange(location: 0, length: text.length)
        text.addAttribute(.conversationTextEffect, value: ConversationTextEffect.shake.rawValue, range: whole)
        text.addAttribute(.conversationEffectInk, value: ConversationPlatformColor.black, range: whole)
        return text
    }

    private let size = CGSize(width: 240, height: 66)

    private func glyphs(_ layer: CALayer) -> [(frame: CGRect, bytes: Data)] {
        (layer.sublayers ?? []).map { glyph in
            let image = glyph.contents as! CGImage
            return (glyph.frame, image.dataProvider!.data! as Data)
        }
    }

    private func waitForGlyphs(_ layer: CALayer) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (layer.sublayers ?? []).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func glyphsNotRenderedYetShowLaterWithTheSamePixels() async throws {
        let text = effectText("shaking every letter of this message")
        let token = "render-ahead-\(UUID().uuidString)"
        let layer = ConversationTextEffectLayer()
        layer.rendersOffMainThread = true
        layer.update(text: text, textSize: size, scale: 2, animated: true, seed: 7, cacheToken: token)
        // Nothing was typeset in the update itself.
        #expect((layer.sublayers ?? []).isEmpty)
        try await waitForGlyphs(layer)
        let ahead = glyphs(layer)
        #expect(!ahead.isEmpty)
        // A layer rendering on the main thread (its own cache entry) draws the same glyphs.
        let reference = ConversationTextEffectLayer()
        reference.update(text: text, textSize: size, scale: 2, animated: true, seed: 7, cacheToken: token + "-main")
        let drawn = glyphs(reference)
        #expect(ahead.count == drawn.count)
        for (a, b) in zip(ahead, drawn) {
            #expect(a.frame == b.frame)
            #expect(a.bytes == b.bytes)
        }
        // Every glyph loops as on the main-thread path.
        #expect((layer.sublayers ?? []).allSatisfy { $0.animation(forKey: "cmux.textEffect") != nil })
    }

    @Test func cachedGlyphsShowAtOnce() {
        let text = effectText("already rendered")
        let token = "render-ahead-\(UUID().uuidString)"
        ConversationTextEffectLayer.prepare(text: text, textSize: size, scale: 2, cacheToken: token)
        let layer = ConversationTextEffectLayer()
        layer.rendersOffMainThread = true
        layer.update(text: text, textSize: size, scale: 2, animated: false, seed: 7, cacheToken: token)
        #expect(!(layer.sublayers ?? []).isEmpty)
    }

    @Test func aRenderFinishingAfterTheLayerMovedOnIsDropped() async throws {
        let text = effectText("this text leaves before its glyphs arrive")
        let token = "render-ahead-\(UUID().uuidString)"
        let layer = ConversationTextEffectLayer()
        layer.rendersOffMainThread = true
        layer.update(text: text, textSize: size, scale: 2, animated: false, seed: 7, cacheToken: token)
        layer.clear()
        // Once the render is done and the main actor has had its turn, the
        // cleared layer still shows nothing.
        let deadline = ContinuousClock.now + .seconds(5)
        while ConversationTextEffectLayer.cachedRendering(text: text, textSize: size, scale: 2, cacheToken: token) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect((layer.sublayers ?? []).isEmpty)
    }
}
