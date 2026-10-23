import CmuxConversationGeometry
import Testing

/// A rounded view that clips its sublayers renders them in an offscreen
/// pass; Liquid Glass draws its rounded shape itself, so the header and
/// composer glass clip only when their content would show past the corners.
/// Simulator perf HUD while the transcript scrolls under them (iOS 26.5):
/// 10 offscreen passes per frame for the six header and composer surfaces.
@Suite struct ConversationGlassClippingTests {
    @Test func liquidGlassDoesNotClipContentInsideItsShape() {
        #expect(!ConversationGlassClipping.clipsToBounds(liquidGlass: true, contentReachesCorners: false))
    }

    /// The composer field clips while its full-width attachment shelf or link card shows.
    @Test func liquidGlassClipsContentThatReachesItsCorners() {
        #expect(ConversationGlassClipping.clipsToBounds(liquidGlass: true, contentReachesCorners: true))
    }

    /// Before iOS 26 the material blur takes its rounded shape from the clip.
    @Test func theBlurFallbackAlwaysClips() {
        #expect(ConversationGlassClipping.clipsToBounds(liquidGlass: false, contentReachesCorners: false))
        #expect(ConversationGlassClipping.clipsToBounds(liquidGlass: false, contentReachesCorners: true))
    }
}
