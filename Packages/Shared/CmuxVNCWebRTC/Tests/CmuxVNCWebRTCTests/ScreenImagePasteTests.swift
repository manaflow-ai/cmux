import CoreGraphics
import CoreVideo
@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// A backend that pastes images, recording each one.
final class PastingBackend: ScreenBackend, @unchecked Sendable {
    // @unchecked: `images` is behind `lock`.
    private let lock = NSLock()
    private var images: [(Data, String)] = []
    var pasted: [(Data, String)] { lock.withLock { images } }
    var inputCapabilities: [String] { [ScreenHostMessage.pasteImageCapability] }
    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {}
    func select(display index: Int) {}
    func handle(_ input: ScreenInput) {}
    func stop() {}
    func pasteImage(_ data: Data, type: String) -> Bool {
        lock.withLock { images.append((data, type)) }
        return true
    }
}

struct ScreenImagePasteTests {
    /// Bytes no chunk boundary lines up with.
    static let image = Data((0 ..< (ScreenInput.pasteImageChunkBytes * 3 + 517)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    /// Every message the viewer sends, through JSON as on the channel.
    static func wire(_ inputs: [ScreenInput]) throws -> [ScreenInput] {
        try inputs.map { try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode($0)) }
    }

    /// Feeds `inputs` to a host step by step; the answers it sends.
    static func host(_ inputs: [ScreenInput], backend: any ScreenBackend, viewOnly: Bool = false) -> [ScreenHostMessage.PasteImageOutcome] {
        var images = ScreenImageAssembler()
        return inputs.compactMap { input in
            ScreenStreamHost.takeImageChunk(input, backend: backend, viewOnly: viewOnly) { images.take($0) }
        }
    }

    @Test func anImageSplitIntoChunksArrivesWholeAndIsPastedOnce() throws {
        let messages = try Self.wire(ScreenInput.pasteImage(Self.image, type: "public.png", id: "a"))
        #expect(messages.count == 4)
        #expect(messages.allSatisfy { $0.t == "paste-image" && $0.n == 4 && $0.id == "a" && $0.f == "public.png" })
        #expect(messages.allSatisfy { (Data(base64Encoded: $0.s ?? "")?.count ?? .max) <= ScreenInput.pasteImageChunkBytes })
        let backend = PastingBackend()
        #expect(Self.host(messages, backend: backend) == [.pasted])
        #expect(backend.pasted.count == 1)
        #expect(backend.pasted.first?.0 == Self.image)
        #expect(backend.pasted.first?.1 == "public.png")
    }

    @Test func aMissingChunkPastesNothing() throws {
        var messages = try Self.wire(ScreenInput.pasteImage(Self.image, type: "public.jpeg", id: "a"))
        messages.remove(at: 2)
        let backend = PastingBackend()
        #expect(Self.host(messages, backend: backend) == [.incomplete])
        #expect(backend.pasted.isEmpty)
    }

    /// A second image that starts before the first ends replaces it: only the second is pasted.
    @Test func aNewImageReplacesAnUnfinishedOne() throws {
        let first = try Self.wire(ScreenInput.pasteImage(Self.image, type: "public.png", id: "a"))
        let second = try Self.wire(ScreenInput.pasteImage(Data("second".utf8), type: "public.png", id: "b"))
        let backend = PastingBackend()
        #expect(Self.host(Array(first.prefix(2)) + second, backend: backend) == [.pasted])
        #expect(backend.pasted.map(\.0) == [Data("second".utf8)])
    }

    @Test func aViewOnlySessionOrAHostThatCannotPasteRefusesOncePerImage() throws {
        let messages = try Self.wire(ScreenInput.pasteImage(Self.image, type: "public.png", id: "a"))
        let pasting = PastingBackend()
        #expect(Self.host(messages, backend: pasting, viewOnly: true) == [.refused])
        #expect(pasting.pasted.isEmpty)
        #expect(Self.host(messages, backend: RecordingBackend()) == [.refused])
    }

    @Test func tooLargeOrUnknownTypesAreNeverSent() {
        #expect(ScreenInput.pasteImage(Data(count: ScreenInput.pasteImageMaximumBytes + 1), type: "public.png").isEmpty)
        #expect(ScreenInput.pasteImage(Self.image, type: "public.data").isEmpty)
        #expect(ScreenInput.pasteImage(Data(), type: "public.png").isEmpty)
    }

    @Test func aChunkClaimingAnUnknownTypeOrTooManyChunksIsRefused() {
        let backend = PastingBackend()
        let chunk = Data("x".utf8).base64EncodedString()
        #expect(Self.host([ScreenInput(t: "paste-image", s: chunk, i: 0, n: 1, id: "a", f: "public.data")], backend: backend) == [.refused])
        #expect(Self.host([ScreenInput(t: "paste-image", s: chunk, i: 0, n: 1_000_000, id: "a", f: "public.png")], backend: backend) == [.refused])
        #expect(backend.pasted.isEmpty)
    }

    @Test func theHostAnswerRoundTrips() throws {
        let data = try JSONEncoder().encode(ScreenHostMessage(pasteImage: .pasted))
        let message = try JSONDecoder().decode(ScreenHostMessage.self, from: data)
        #expect(message.pasteImageOutcome == .pasted)
        #expect(ScreenHostMessage(t: "displays").pasteImageOutcome == nil)
    }

    /// An older host's input decoding never sees the new keys: a plain message encodes without them.
    @Test func otherInputEncodesWithoutPasteKeys() throws {
        let text = String(decoding: try JSONEncoder().encode(ScreenInput(t: "text", s: "hi")), as: UTF8.self)
        #expect(!text.contains("\"n\"") && !text.contains("\"id\"") && !text.contains("\"f\""))
    }
}

#if os(macOS)
/// What the Mac's capture backend does with a pasted image (pasteboard recorded, events captured).
struct ScreenCaptureBackendPasteTests {
    final class Board: @unchecked Sendable {
        // @unchecked: `writes` is behind `lock`.
        private let lock = NSLock()
        private var writes: [(Data, String)] = []
        var written: [(Data, String)] { lock.withLock { writes } }
        func write(_ data: Data, _ type: String) { lock.withLock { writes.append((data, type)) } }
    }

    @Test func aPastedImageGoesOnThePasteboardThenCommandVIsPressed() {
        let posted = PostedEvents(), board = Board()
        let backend = ScreenCaptureBackend(log: { _ in }, timing: nil, input: EventInjector(source: nil) { posted.append($0) },
                                           writePasteboard: { data, type in board.write(data, type); return true })
        #expect(backend.pasteImage(Data("png".utf8), type: "public.png"))
        #expect(board.written.map(\.1) == ["public.png"])
        let keys = posted.of([.keyDown, .keyUp])
        // V down and up, both with ⌘ held.
        let v = keys.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 9 }
        #expect(v.map(\.type) == [.keyDown, .keyUp])
        #expect(v.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    @Test func bytesThatAreNoImageAreNotPasted() {
        let posted = PostedEvents()
        let backend = ScreenCaptureBackend(log: { _ in }, timing: nil, input: EventInjector(source: nil) { posted.append($0) },
                                           writePasteboard: { _, _ in false })
        #expect(!backend.pasteImage(Data("nope".utf8), type: "public.png"))
        #expect(posted.all.isEmpty)
        #expect(!ScreenCaptureBackend.writeGeneralPasteboard(Data("nope".utf8), type: "public.png"))
    }
}
#endif
