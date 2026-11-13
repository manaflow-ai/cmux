import AppKit
import CmuxHomeCore
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Pictures of a 4,896-line paste in the Home transcript, light and dark, for a Before | After review
/// (Lawrence 2026-11-12: "if users sends too much stuff we should just write it to a file"). Before: the owner
/// refuses the text (past its 64 KiB limit), so the bubble stays Not Delivered. After: the message the owner
/// now commits in its place, a `text/plain` file part and a short prompt (cmux-tui `conversation_spill.rs`).
/// Writes `$CMUX_CAPTURE_DIR/oversized-{before,after}-{light,dark}.png`; runs only when `CMUX_CAPTURE_DIR` is set.
@MainActor @Suite(.serialized) struct HomeOversizedSendCaptureTests {
    static let folder = ProcessInfo.processInfo.environment["CMUX_CAPTURE_DIR"]
    static let dm = ConversationID("conv_austin")
    static let paste = (1...4896).map { String(format: "line %04d of the pasted log: request finished in 12 ms, status 200", $0) }
        .joined(separator: "\n")

    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    /// The short text the owner commits for `text` saved as `name` (the format of `conversation_spill.rs`).
    static func prompt(_ text: String, name: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let head = lines.prefix(40).joined(separator: "\n")
        let tail = lines.suffix(40).joined(separator: "\n")
        let size = "\((text.utf8.count + 999) / 1000) KB"
        let count = NumberFormatter.localizedString(from: NSNumber(value: lines.count), number: .decimal)
        let hidden = NumberFormatter.localizedString(from: NSNumber(value: lines.count - 80), number: .decimal)
        return "The user sent a long message (\(count) lines, \(size)), so it is attached as the file \(name) instead of written here.\n\n"
            + "Read the file with your tools and carry out the user's instructions in it; check both its start and its end.\n\n"
            + "Its first 40 lines:\n```\n\(head)\n```\n\n[\(hidden) lines not shown]\n\nIts last 40 lines:\n```\n\(tail)\n```"
    }

    @Test(.enabled(if: folder != nil, "set CMUX_CAPTURE_DIR to write the captures"), arguments: [true, false])
    func theLongPaste(light: Bool) async throws {
        for after in [false, true] {
            let source = MockHomeSource(options: .immediate)
            let store = HomeStore(source: source)
            store.start()
            await until { store.isOnline && !store.rows.isEmpty }
            await store.open(Self.dm)
            let view = MessagesLabHomeView(store: store, conversation: Self.dm, me: ParticipantID("user_me"), wake: NoWake())
            defer { view.stop() }
            let key = IdempotencyKey("send-oversized")
            if after {
                let bytes = Data(Self.paste.utf8)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let name = "message-\(hash.prefix(12)).txt"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try bytes.write(to: url)
                let ref = try await source.upload(AttachmentUpload(conversation: Self.dm, fileURL: url,
                                                                   ref: AttachmentRef(hash: hash, name: name, mimeType: "text/plain", byteCount: bytes.count),
                                                                   progress: { _ in }))
                _ = try? await store.perform(.sendMessage(conversation: Self.dm, parts: [.attachment(ref), .text(Self.prompt(Self.paste, name: name))]), key: key)
            } else {
                await source.failNextSubmits(of: key, times: 1, with: .invalid("invalid_parts"))
                _ = try? await store.perform(.sendMessage(conversation: Self.dm, parts: [.text(Self.paste)]), key: key)
            }
            await until { store.transcript(for: Self.dm).contains { $0.key == key && $0.delivery != .pending } }
            try write(view, light: light, name: "oversized-\(after ? "after" : "before")-\(light ? "light" : "dark")")
        }
    }

    func write(_ view: MessagesLabHomeView, light: Bool, name: String) throws {
        let size = CGSize(width: 720, height: 640)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { window.close() }
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let out = URL(fileURLWithPath: try #require(Self.folder)).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
