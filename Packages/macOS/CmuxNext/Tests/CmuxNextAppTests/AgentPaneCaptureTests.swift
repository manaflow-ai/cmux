@testable import CmuxNextAgentPane
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// What `composer.capture` answers the page: a capture named for when it was taken (so two in one
/// prompt differ); the original, as `screencapture` wrote it at any size, saved through the chat's
/// own upload stager inside the click's one gesture, by its path; and a bounded preview for the
/// model. The page never sends the bytes back, which would need a second gesture (#26958 review).
@MainActor
struct AgentPaneCaptureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let taken = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                              year: 2026, month: 10, day: 11, hour: 14, minute: 32, second: 5).date!
    /// A 1x1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private static let saved = "/Users/dev/Library/Application Support/cmux/Chat Uploads/sessions/s1/u/0/Screenshot.png"

    /// A pane for chat `session` (nil: a fresh chat, before its first prompt) whose upload stager
    /// records each request and the session it was asked for, and keeps the bytes it got. Like
    /// AgentChatUploads' stager, it takes a nil session for a new chat.
    private final class Rig {
        let model: AgentPaneModel
        var requests: [AgentPaneUploadStageRequest] = []
        var sessions: [String?] = []
        var received = Data()

        init(stages: Bool = true, session: String? = "s1") {
            model = AgentPaneModel(host: NoHost(), sessionId: session)
            guard stages else { return }
            model.onUploadStage = { [weak self] in
                { request, asked in
                    guard let self, asked == nil || asked == session else { return AgentPaneReply.failure(code: "upload_failed", message: "") }
                    requests.append(request)
                    sessions.append(asked)
                    switch request {
                    case .begin(_, let size, _, _): return AgentPaneReply.success(["token": "t", "size": size, "chunkSize": 512 * 1024])
                    case .chunk(_, _, let data):
                        received.append(data)
                        return AgentPaneReply.success(["offset": received.count])
                    case .finish: return AgentPaneReply.success(["path": AgentPaneCaptureTests.saved])
                    case .cancel: return AgentPaneReply.success()
                    }
                }
            }
        }

        func capture(_ bytes: Data, gesture: Bool = true) async -> [String: Any] {
            if gesture { model.transport.gestures.record(click: true) }
            return await AgentPaneCapture.reply(to: "screen", in: model, taken: AgentPaneCaptureTests.taken) { _, file in
                bytes.isEmpty || (try? bytes.write(to: file)) != nil
            }
        }
    }

    private static func value(_ reply: [String: Any]) -> [String: Any]? { reply["value"] as? [String: Any] }
    private static func errorCode(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    @Test func aCaptureIsNamedForWhenItWasTaken() {
        #expect(AgentPaneCapture.name(taken: Self.taken) == "Screenshot 2026-10-11 14.32.05.png")
    }

    /// The review's BLOCK: the capture used the click's only gesture, so the page's own upload of the
    /// original was refused (`gesture_required`). The host saves the original in the same gesture.
    @Test func aCaptureSavesItsOriginalWithinItsOneGestureAndAnswersItsPath() async throws {
        let rig = Rig()
        let reply = await rig.capture(Self.png)
        let answer = try #require(Self.value(reply), "\(reply)")
        let original = try #require(answer["original"] as? [String: Any])
        #expect(original["path"] as? String == Self.saved)
        #expect(original["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == Self.png.base64EncodedString())
        #expect(rig.requests == [
            .begin(name: "Screenshot 2026-10-11 14.32.05.png", size: Self.png.count, batchToken: nil, batch: nil),
            .chunk(token: "t", offset: 0, data: Self.png),
            .finish(token: "t"),
        ])
        #expect(rig.received == Self.png)
        // One credit: the click's is used, and a capture without a new click is refused before it runs.
        #expect(!rig.model.transport.gestures.isAvailable)
        let again = await rig.capture(Self.png, gesture: false)
        #expect(Self.errorCode(again) == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(rig.requests.count == 3)
    }

    /// #26958 review: a fresh chat has no session until its first prompt, and its capture still
    /// saves the original: the stager is asked for no session, as for the page's own new-chat upload.
    @Test func aCaptureInAFreshChatSavesItsOriginal() async throws {
        let rig = Rig(session: nil)
        #expect(rig.model.sessionId == nil)
        let answer = try #require(Self.value(await rig.capture(Self.png)))
        #expect((answer["original"] as? [String: Any])?["path"] as? String == Self.saved)
        #expect(rig.requests == [
            .begin(name: "Screenshot 2026-10-11 14.32.05.png", size: Self.png.count, batchToken: nil, batch: nil),
            .chunk(token: "t", offset: 0, data: Self.png),
            .finish(token: "t"),
        ])
        #expect(rig.sessions == [nil, nil, nil])
        #expect(rig.received == Self.png)
    }

    /// Leo, 2026-10-26: "WE NEED ARBITARRILY LARGE FILES OF ANY TYPE". A capture past the preview's
    /// budget is saved as taken, byte for byte and chunk by chunk; only the preview is scaled.
    @Test func aLargeCaptureIsSavedAsTakenAndOnlyItsPreviewIsScaled() async throws {
        let large = try Self.noisePNG(width: 2400, height: 1600)
        try #require(large.count > AgentPaneCapture.previewMaxBytes)
        let rig = Rig()
        let answer = try #require(Self.value(await rig.capture(large)))
        #expect((answer["original"] as? [String: Any])?["path"] as? String == Self.saved)
        #expect(rig.received == large)
        #expect(rig.requests.filter { if case .chunk = $0 { true } else { false } }.count == (large.count + 512 * 1024 - 1) / (512 * 1024))
        let preview = try #require((answer["data"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(preview.count < large.count)
        let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let side = max(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, properties[kCGImagePropertyPixelHeight] as? Int ?? .max)
        #expect(side <= AgentPaneCapture.previewMaxSide)
    }

    @Test func aCancelledPickAnswersCancelledAndSavesNothing() async {
        let rig = Rig()
        let answer = Self.value(await rig.capture(Data()))
        #expect(answer?["cancelled"] as? Bool == true)
        #expect(answer?["original"] == nil)
        #expect(rig.requests.isEmpty)
    }

    /// A chat whose host saves nothing (no stager): the preview still attaches, with no original.
    @Test func aChatThatSavesNothingGetsThePreviewOnly() async throws {
        let rig = Rig(stages: false)
        let answer = try #require(Self.value(await rig.capture(Self.png)))
        #expect(answer["data"] as? String == Self.png.base64EncodedString())
        #expect(answer["original"] == nil)
    }

    /// A PNG of `width` x `height` noise, which PNG cannot compress.
    private static func noisePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let rows = context.bytesPerRow
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: rows * height)
        var seed: UInt32 = 0x2545_F491
        for row in 0..<height {
            for column in 0..<(width * 4) {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                pixels[row * rows + column] = UInt8(truncatingIfNeeded: seed)
            }
        }
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
