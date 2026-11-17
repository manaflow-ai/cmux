import CmuxNextDictation
import Foundation
import Testing

/// The cmux Computer Use helper's `display_still` as Voice Room sees it: each look takes the next reply.
private final class StillsHost: ChiefScreenCaptureHost, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[String: Any]]
    private(set) var sent: [[String: Any]] = []

    init(_ replies: [[String: Any]]) { self.replies = replies }

    @concurrent func screenRecordingAllowed() async throws -> Bool { true }
    @concurrent func requestScreenRecording() async throws {}
    @concurrent func displayStill(_ arguments: [String: Any]) async throws -> [String: Any] {
        lock.withLock {
            sent.append(arguments)
            return replies.removeFirst()
        }
    }
    func isHelperGone(_ error: any Error) -> Bool { false }
    func refusal(_ error: any Error) -> String? { nil }
}

/// ``VoiceRoomScreenReader`` reads the screen through the helper, never in this app.
@Suite struct VoiceRoomScreenReaderTests {
    static let thumb = Data(repeating: 7, count: VoiceRoomFrameSignature.width * VoiceRoomFrameSignature.height)

    @Test func aChangedFrameIsASampleWithAKeyframeAndAnUnchangedOneIsNil() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let host = StillsHost([
            ["signature": Self.thumb.base64EncodedString(), "changed": true, "jpeg": jpeg.base64EncodedString()],
            ["signature": Self.thumb.base64EncodedString(), "changed": false],
        ])
        let frames = FileManager.default.temporaryDirectory.appending(path: "voice-room-frames-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: frames) }
        let reader = VoiceRoomScreenReader(host: host, frames: frames)

        let sample = try #require(try await reader.read(changedSince: nil))
        #expect(sample.signature == VoiceRoomFrameSignature(pixels: [UInt8](Self.thumb)))
        let saved = try FileManager.default.contentsOfDirectory(atPath: frames.path).filter { $0.hasSuffix(".jpg") }
        #expect(saved.count == 1)
        #expect(try saved.first.map { try Data(contentsOf: frames.appending(path: $0)) } == jpeg)

        #expect(try await reader.read(changedSince: sample.signature) == nil)
        #expect(host.sent.count == 2)
        #expect(host.sent.last?["previous_signature"] as? String == Self.thumb.base64EncodedString())
        #expect((host.sent.first?["exclude_pids"] as? [Int])?.contains(Int(ProcessInfo.processInfo.processIdentifier)) == true)
    }
}
