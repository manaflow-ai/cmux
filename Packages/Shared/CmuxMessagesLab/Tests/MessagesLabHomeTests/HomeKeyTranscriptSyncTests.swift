import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Each key in the field ends in `TranscriptScrollView.syncFromModel`, which puts the transcript's clip view at the
/// model's offset. With the transcript pinned to its bottom, the model's offset is past the document's end and
/// AppKit stops the clip short of it, so the clip was never "at" the offset and every key set its bounds origin
/// again: no move, but each call marked the window's tracking areas dirty, and the next display walked every view
/// of the window to update them (about a quarter of the slow keys' display work at a 3,000-character draft: cmux21
/// xctrace, 300 keys; a1250, 2026-11-20). The real Home view over the mock owner, in an offscreen window.
@MainActor @Suite(.serialized) struct HomeKeyTranscriptSyncTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var field: FieldTextView { view.controller.demo!.compose.textView.view }
        var scroll: TranscriptScrollView { view.controller.host.scrollView }
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        func type(_ text: String) {
            field.insertText(text, replacementRange: field.selectedRange())
            frame()
        }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 40, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let r = Rig(store: store, window: window, view: view)
        r.frame()
        r.window.makeFirstResponder(r.field)
        return r
    }

    /// Keys that move no row (a long draft, the field at its tallest) set the transcript's clip origin no more.
    @Test func keysThatMoveNoRowLeaveTheTranscriptClipAlone() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type(String(repeating: "the chief reads your note and answers it ", count: 75))
        r.type("x")
        let origin = r.scroll.clip.bounds.origin
        let syncs = TranscriptScrollView.modelSyncs
        for ch in "abcdefgh" { r.type(String(ch)) }
        try #require(r.scroll.clip.bounds.origin == origin, "the keys moved the transcript: not the case under test")
        #expect(TranscriptScrollView.modelSyncs == syncs, "8 keys that moved no row set the clip origin \(TranscriptScrollView.modelSyncs - syncs) times")
    }

    /// The clip still follows the model: after a new line grows the field, it sits where AppKit puts the model's offset.
    @Test func theClipFollowsTheModelWhenTheFieldGrows() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type("a short note")
        r.type("\n")
        r.type("a second line")
        let cv = try #require(r.scroll.collection)
        let target = cv.contentOffset.y + r.scroll.shift
        let clip = r.scroll.clip
        let expected = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: target), size: clip.bounds.size)).origin.y
        // AppKit rounds the clip's origin to the backing pixel grid (half a point at 2x, a point at 1x).
        let pixel = 1 / max(1, r.window.backingScaleFactor)
        #expect(abs(clip.bounds.origin.y - expected) <= pixel + 0.001, "the clip is at \(clip.bounds.origin.y), the model's offset constrains to \(expected)")
    }
}
