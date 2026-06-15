import Foundation
import Testing
@testable import CMUXMobileCore

/// Behavior tests for the pasted-image size selection that prevents iOS from
/// handing the sync transport a frame it is guaranteed to reject.
@Suite struct MobilePasteImageSizingTests {
    /// The largest raw image the helper accepts must base64-encode to a payload
    /// that still fits the frame budget *after* the JSON envelope reserve and the
    /// worst-case slash-escaping multiplier. This is the assertion that proves the
    /// fix: the previous code capped raw bytes at 8 MB, whose base64 (~10.6 MB)
    /// overflowed the 8 MB frame cap and threw.
    @Test func maxRawImageBase64FitsTheFrameBudget() {
        let sizing = MobilePasteImageSizing()
        let maxRaw = sizing.maximumRawImageByteCount

        let base64Len = sizing.base64ByteCount(forRawByteCount: maxRaw)
        let worstCaseSerialized = base64Len * sizing.jsonEscapeWorstCaseFactor + sizing.envelopeReserveBytes
        #expect(worstCaseSerialized <= sizing.frameByteCapacity)
    }

    /// The largest accepted raw image must still fit the frame after a *real*
    /// adversarial JSON serialization, including the `auth` object the RPC client
    /// attaches *after* sizing: `0xFF` bytes base64-encode entirely to `/`, which
    /// Apple's `JSONSerialization` escapes as `\/` (the worst case the sizing
    /// helper budgets for), and the request also carries a large
    /// `stack_access_token` plus `attach_token` (multi-KB JWTs injected by
    /// `requestDataWithAuth`). This guards against both the slash-escaping
    /// regression and the post-sizing auth-token reserve that autoreview caught:
    /// if the envelope reserve did not cover the auth tokens, an at-the-cap image
    /// would overflow the frame once auth was attached.
    @Test func acceptedMaxRawSurvivesWorstCaseJSONSerialization() throws {
        let sizing = MobilePasteImageSizing()
        let raw = Data(repeating: 0xFF, count: sizing.maximumRawImageByteCount)
        // Stand-ins for the JWTs the RPC client injects post-sizing, sized to a
        // realistic worst case (a long Stack access token and an attach token).
        let largeStackToken = String(repeating: "a", count: 7 * 1024)
        let largeAttachToken = String(repeating: "b", count: 7 * 1024)
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": "terminal.paste_image",
            "params": [
                "workspace_id": UUID().uuidString,
                "surface_id": UUID().uuidString,
                "image_base64": raw.base64EncodedString(),
                "image_format": "png",
                "client_id": UUID().uuidString,
            ],
            "auth": [
                "stack_access_token": largeStackToken,
                "attach_token": largeAttachToken,
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        #expect(payload.count <= MobileSyncFrameCodec.defaultMaximumFrameByteCount)
    }

    /// The derived raw cap must be safely under the Mac's 10 MB raw clipboard cap
    /// (the base64 frame cap is the binding constraint) and well under the old
    /// 8 MB cap that produced silently-failing pastes, while staying useful.
    @Test func maxRawImageIsUnderTheMacClipboardCap() {
        let sizing = MobilePasteImageSizing()
        #expect(sizing.maximumRawImageByteCount < 10 * 1024 * 1024)
        #expect(sizing.maximumRawImageByteCount < 8 * 1024 * 1024)
        // Sanity: it is still large enough to be useful (> 2 MB raw) after the
        // worst-case slash-escaping budget halves the base64 allowance.
        #expect(sizing.maximumRawImageByteCount > 2 * 1024 * 1024)
    }

    @Test func fitsBoundaryIsInclusiveAtTheCap() {
        let sizing = MobilePasteImageSizing()
        let maxRaw = sizing.maximumRawImageByteCount
        #expect(sizing.fits(rawByteCount: maxRaw))
        #expect(!sizing.fits(rawByteCount: maxRaw + 1))
        #expect(!sizing.fits(rawByteCount: 0))
    }

    /// A realistic, sparse-slash image that is far larger than the worst-case raw
    /// cap (~3 MB) but whose *actual* base64 has few slashes must be **accepted**.
    /// This is the regression guard for the over-rejection autoreview caught: the
    /// old worst-case-only check would have dropped a normal ~5 MB photo that fits
    /// the real 8 MB frame.
    @Test func acceptsRealisticLargeImageThatActuallyFits() {
        let sizing = MobilePasteImageSizing()
        // Zero bytes base64-encode to all "A" (no slashes), so this 5 MB payload's
        // serialized image field is ~6.67 MB, comfortably under the 8 MB frame even
        // though 5 MB is well over the ~3 MB worst-case raw cap.
        let fiveMB = 5 * 1024 * 1024
        #expect(fiveMB > sizing.maximumRawImageByteCount)
        let sparseSlashImage = Data(repeating: 0x00, count: fiveMB)
        #expect(sizing.fits(imageData: sparseSlashImage))
    }

    /// The all-`0xFF` adversarial image (base64 is entirely slashes) hits the
    /// worst-case boundary: at the worst-case raw cap it just fits, and one byte
    /// over the cap it does not. This proves the actual-size check still rejects a
    /// genuinely overflowing payload, so accepting realistic images did not weaken
    /// the safety bound.
    @Test func rejectsAllSlashImageThatOverflowsTheFrame() {
        let sizing = MobilePasteImageSizing()
        let atCap = Data(repeating: 0xFF, count: sizing.maximumRawImageByteCount)
        #expect(sizing.fits(imageData: atCap))
        let overCap = Data(repeating: 0xFF, count: sizing.maximumRawImageByteCount + 3)
        #expect(!sizing.fits(imageData: overCap))
        #expect(!sizing.fits(imageData: Data()))
    }

    /// PNG is preferred; when it overflows but the JPEG fallback fits, the JPEG
    /// candidate is chosen. Mirrors the paste path's PNG-then-JPEG ordering, and
    /// the helper decides on the candidates' actual serialized sizes.
    @Test func picksFirstEncodingThatFitsInPriorityOrder() {
        let sizing = MobilePasteImageSizing()
        // An all-slash (0xFF) PNG over the cap, and a sparse-slash (0x00) JPEG that
        // fits at the same raw size: the JPEG must win.
        let overCapRaw = sizing.maximumRawImageByteCount + 1024
        let oversizedPNG = Data(repeating: 0xFF, count: overCapRaw)
        let fittingJPEG = Data(repeating: 0x00, count: overCapRaw)
        #expect(!sizing.fits(imageData: oversizedPNG))
        #expect(sizing.fits(imageData: fittingJPEG))
        let picked = sizing.firstEncodingThatFits([
            (label: "png", encode: { oversizedPNG }),
            (label: "jpg", encode: { fittingJPEG }),
        ])
        #expect(picked?.label == "jpg")
        #expect(picked?.data == fittingJPEG)

        // When PNG already fits, it wins and the JPEG encoder is never invoked
        // (lazy, so no second full encoding is produced or retained).
        let smallPNG = Data(repeating: 0x00, count: 1024)
        var jpegEncoderRan = false
        let pickedFirst = sizing.firstEncodingThatFits([
            (label: "png", encode: { smallPNG }),
            (label: "jpg", encode: { jpegEncoderRan = true; return Data(repeating: 0x00, count: 512) }),
        ])
        #expect(pickedFirst?.label == "png")
        #expect(jpegEncoderRan == false)
    }

    /// When every candidate overflows, the helper returns nil so the caller drops
    /// the image and surfaces a "too large" notice instead of sending an
    /// oversized frame.
    @Test func returnsNilWhenNoEncodingFits() {
        let sizing = MobilePasteImageSizing()
        let overCapRaw = sizing.maximumRawImageByteCount + 4
        let picked = sizing.firstEncodingThatFits([
            (label: "png", encode: { Data(repeating: 0xFF, count: overCapRaw) }),
            (label: "jpg", encode: { Data(repeating: 0xFF, count: overCapRaw) }),
        ])
        #expect(picked == nil)
    }

    /// base64 length follows the 4 * ceil(n/3) padding rule.
    @Test(arguments: [
        (0, 0),
        (1, 4),
        (2, 4),
        (3, 4),
        (4, 8),
        (6, 8),
        (7, 12),
    ])
    func base64ByteCountMatchesPaddedEncoding(rawCount: Int, expected: Int) {
        let sizing = MobilePasteImageSizing()
        #expect(sizing.base64ByteCount(forRawByteCount: rawCount) == expected)
        // Cross-check against Foundation's real base64 encoder for non-empty input.
        if rawCount > 0 {
            let encoded = Data(repeating: 0xAB, count: rawCount).base64EncodedString()
            #expect(encoded.utf8.count == expected)
        }
    }
}
