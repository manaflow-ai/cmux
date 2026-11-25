import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The send's flying bubble draws the draft from images made ahead of the send (`MorphBubble.prepare`: the
/// draft's text parts, its layout at the window width, the text and its blur). They were made again for each
/// key, the whole draft each time, at the moment the key's own frame was drawn: at a 3,000-character draft,
/// about 5 ms of CPU per key beside that frame (cmux21, `sample` of 300 keys, real app; a1250, 2026-11-20).
/// Only the draft a send takes needs them: they are made once the draft rests, and an emptied draft (a send,
/// a clear) drops a pending one. The real Home view over the mock owner, in an offscreen window.
@MainActor @Suite(.serialized) struct HomeComposerSendPrepTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// Waits up to `seconds` of real time (the rest delay is real time) for `condition`.
    private func within(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var field: FieldTextView { view.controller.demo!.compose.textView.view }
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
        let options = MockHomeSource.Options(chiefHistory: 12, latency: .zero, replyDelay: .seconds(3600))
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

    /// The draft the store holds (what a send takes).
    private func draft(_ r: Rig) -> String { r.view.controller.store?.state.ui.draft.text ?? "" }

    /// What `MorphBubble.preparedDraftHash()` holds for a draft.
    private func key(_ text: String) -> Int { text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue }

    /// A unique 3,000-character draft (other suites type into their own Home views meanwhile).
    private func longDraft() -> String {
        let tag = UUID().uuidString
        return String(String(repeating: "the chief reads your note and answers \(tag) ", count: 60).prefix(3000))
    }

    /// Keys typed into a long draft make no send images in their own frames (once a key's queued work is done, the
    /// newest images are not its draft's); once the draft rests, the images are made for the draft a send takes.
    @Test func aKeyLeavesTheSendImagesToTheRestingDraft() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type(longDraft())
        for (i, ch) in "abcde".enumerated() {
            r.type(String(ch))
            MorphBubble.drainPrepare()
            #expect(MorphBubble.preparedDraftHash() != key(draft(r)), "key \(i + 1) rendered the whole draft's send images in its own frame")
        }
        // The newest draft of any Home view is the one rendered (one shared slot): a suite typing in parallel can
        // take the rest from this one, so a fresh rest is tried up to five times.
        var rested = false
        for attempt in 0..<5 where !rested {
            if attempt > 0 { r.type("y") }
            let last = draft(r)
            rested = await within(1.5) {
                MorphBubble.drainPrepare()
                return MorphBubble.preparedDraftHash() == key(last)
            }
        }
        #expect(rested, "the resting draft got no send images: a send would draw them on the main thread")
    }

    /// A draft emptied before it rests (a send, a clear) makes no send images: its pending render is dropped.
    @Test func anEmptiedDraftDropsItsPendingSendImages() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type(longDraft())
        r.type("x")
        let typed = draft(r)
        r.field.selectAll(nil)
        r.field.deleteBackward(nil)
        r.frame()
        #expect(draft(r).isEmpty)
        try? await Task.sleep(for: .milliseconds(400))
        MorphBubble.drainPrepare()
        #expect(MorphBubble.preparedDraftHash() != key(typed), "an emptied draft still got its send images")
    }

    /// The images of a layer tree that has contents (the flying bubble's text and its blur).
    private func images(in layer: CALayer) -> [CGImage] {
        var out: [CGImage] = []
        func walk(_ l: CALayer) {
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID { out.append(c as! CGImage) }
            l.sublayers?.forEach(walk)
            l.mask.map(walk)
        }
        walk(layer)
        return out
    }

    /// A send sooner than the rest after the last key (no send images made yet) still flies its bubble with the
    /// draft's text: the send draws its own images then, as it did before the images waited for the rest.
    @Test func aSendBeforeTheRestFliesItsBubbleWithItsText() async throws {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        let r = try await rig()
        defer { r.close() }
        r.type("a quick note \(UUID().uuidString) sent at once")
        r.type("!")
        let typed = draft(r)
        MorphBubble.drainPrepare()
        try #require(MorphBubble.preparedDraftHash() != key(typed), "the draft rested before the send: not the case under test")
        let demo = try #require(r.view.controller.demo)
        let hits = MorphBubble.preparedHits
        #expect(r.view.projection.send() == nil, "the send was refused")
        r.frame()
        let mb = try #require(demo.morphs.values.first, "a send right after the last key flew no bubble")
        #expect(MorphBubble.preparedHits == hits, "the send used images made for another draft")
        let drawn = images(in: mb.sharpHolder) + images(in: mb.insideClip)
        #expect(drawn.contains { $0.width > 0 && $0.height > 0 }, "the flying bubble has no text image")
    }
}
