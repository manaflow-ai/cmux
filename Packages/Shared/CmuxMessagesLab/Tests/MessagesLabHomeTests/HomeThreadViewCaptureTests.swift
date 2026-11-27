import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The Chief chat's thread view next to the transcript it opens from (https://github.com/manaflow-ai/cmux/issues/26686):
/// the real Home view over a real `HomeStore` on the mock owner, offscreen. The Chief's root holds a Markdown
/// link, I answer it and the Chief answers me; the picture at `.build/home-thread-view.png` (a fleet step
/// returns it with `--artifact`) shows the transcript (left) and the open thread (right).
@MainActor @Suite(.serialized) struct HomeThreadViewCaptureTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let rootText = "Opened [Fix the update check](cmux://workspace/ws_26686) for the Sparkle timer."

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// iMessage's thread view has no header: the root bubble is the view's first row, drawn as in the
    /// transcript. The Chief chat drew the root's raw Markdown and an "Open · Unassigned" row above it.
    @Test func theThreadViewHasNoHeaderAboveTheRoot() async throws {
        try await withThread { view, _, _ in
            let demo = try #require(view.controller.demo)
            #expect(demo.threadHeaderFrame == nil, "the thread view draws a header above the root")
            let first = try #require(demo.threadSpecs.first { if case .part = $0.kind { true } else { false } })
            guard case let .part(row) = first.kind, case let .text(text, _) = row.part else {
                Issue.record("the thread view's first bubble is not the root's text"); return
            }
            #expect(text.contains("Fix the update check"), "the thread view's first bubble is \(text), not the root")
        }
    }

    @Test func theThreadViewNextToTheTranscript() async throws {
        try await withThread { view, size, transcript in
            let threadView = try #require(render(view, size: size))
            try write([transcript, threadView], size: size, to: ".build/home-thread-view.png")
        }
    }

    /// The real view with the thread posted and then open; `body` gets the view, its size and the transcript's picture.
    private func withThread(_ body: (MessagesLabHomeView, CGSize, CGImage) throws -> Void) async throws {
        MessagesLabHomeView.reduceMotionOverride = true
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        RowCell.synchronousBitmaps = true
        defer { RowCell.synchronousBitmaps = false }
        let options = MockHomeSource.Options(chiefHistory: 6, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)
        let size = CGSize(width: 560, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { view.stop(); window.close(); store.stop() }
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        // The owner posts the Chief's root, my reply and the Chief's answer (thread_root = the root).
        let root = MessageID("msg_thread_root")
        let thread: [(MessageID, ParticipantID, String, MessageID?)] = [
            (root, chief, Self.rootText, nil),
            (MessageID("msg_thread_a"), me, "is it on the branch yet?", root),
            (MessageID("msg_thread_b"), chief, "Yes, pushed a minute ago.", root),
        ]
        for (id, author, text, parent) in thread {
            let summary = try #require(store.summary(Self.conversation))
            let rev = store.mirror.revision(of: .conversation(Self.conversation)) + 1
            store.handle(.message(CmuxHomeCore.Message(id: id, conversation: Self.conversation, seq: summary.lastSeq + 1,
                                                       clientMessageID: IdempotencyKey(id.rawValue), author: author,
                                                       parts: [.text(text)], createdAt: Date(),
                                                       replyTo: parent.map { CmuxHomeCore.PartRef(message: $0) },
                                                       threadRoot: parent), rev: rev))
        }
        frame()
        let transcript = try #require(render(view, size: size))

        let lab = try #require(view.controller.store?.state.conversation.messages.first {
            $0.parts.contains { if case let .text(t, _) = $0 { t.contains("Fix the update check") } else { false } }
        })
        view.controller.store?.dispatch(.openThreadPath([MessagesLabHome.PartRef(messageId: lab.id, partIndex: 0)]))
        frame()
        let demo = try #require(view.controller.demo)
        try #require(demo.threadOpen, "the thread view did not open")
        try body(view, size, transcript)
    }

    private func render(_ view: NSView, size: CGSize) -> CGImage? {
        view.displayIfNeeded()
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: 2, y: 2)
        if view.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        view.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    private func write(_ images: [CGImage], size: CGSize, to path: String) throws {
        let fw = Int(size.width * 2), fh = Int(size.height * 2), gap = 16
        let sheet = try #require(CGContext(data: nil, width: images.count * fw + (images.count - 1) * gap, height: fh, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sheet.setFillColor(CGColor(gray: 0.5, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        for (i, image) in images.enumerated() { sheet.draw(image, in: CGRect(x: i * (fw + gap), y: 0, width: fw, height: fh)) }
        let image = try #require(sheet.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
