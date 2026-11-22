import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// `ScaleKeeper` puts the content-less layers of a Home tab's trees at the tab's scale. Each engine change asked it to
/// walk every tree of every tab, and a key in the field is an engine change: at a 3,000-character draft the walk was
/// about 0.3 ms of each key's main-thread work (cmux21 `sample`, 300 keys; a1250, 2026-11-20). A key that keeps the
/// field's frame changes only the compose layers (the window view's commit touches no row), so it asks for the compose
/// tree alone. The real Home view over the mock owner, in an offscreen window.
@MainActor @Suite(.serialized) struct HomeKeyScaleWalkTests {
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
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        /// One key: the text goes in and the field reports it, with no frame after it.
        func key(_ text: String) { field.insertText(text, replacementRange: field.selectedRange()) }
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
        // A draft of a few lines, so a key in it keeps the field's frame.
        r.key(String(repeating: "the chief reads your note ", count: 12))
        r.frame()
        return r
    }

    private func draft(_ r: Rig) -> String { r.view.controller.store?.state.ui.draft.text ?? "" }

    /// A key that keeps the field's frame asks for a walk of its tab's compose tree only.
    @Test func aKeyThatKeepsTheFieldWalksOnlyTheComposeTree() async throws {
        let r = try await rig()
        defer { r.close() }
        let demo = try #require(r.view.controller.demo)
        let host = r.view.controller.host
        let field = demo.compose.fieldRect
        ScaleKeeper.shared.apply()
        try #require(ScaleKeeper.shared.pendingScope(of: host) == nil)
        r.key("x")
        try #require(draft(r).hasSuffix("x"), "the key did not reach the draft")
        try #require(demo.compose.fieldRect == field, "the key changed the field's frame: not the case under test")
        #expect(ScaleKeeper.shared.pendingScope(of: host) == .compose, "a key that kept the field asked for a walk of every tree")
    }

    /// A key that changes the field's frame (a new line) moves the rows: every tree is walked.
    @Test func aKeyThatGrowsTheFieldWalksEveryTree() async throws {
        let r = try await rig()
        defer { r.close() }
        let demo = try #require(r.view.controller.demo)
        let host = r.view.controller.host
        let field = demo.compose.fieldRect
        ScaleKeeper.shared.apply()
        r.key("\n")
        try #require(demo.compose.fieldRect != field, "a new line kept the field's frame: not the case under test")
        #expect(ScaleKeeper.shared.pendingScope(of: host) == .all, "a key that grew the field did not ask for a walk of every tree")
    }

    /// A walk of the compose tree puts a content-less layer added there at the tab's scale.
    @Test func aComposeWalkPutsANewComposeLayerAtTheTabScale() async throws {
        let r = try await rig()
        defer { r.close() }
        let demo = try #require(r.view.controller.demo)
        let host = r.view.controller.host
        let added = CALayer()
        added.contentsScale = 7
        demo.compose.overlay.addSublayer(added)
        defer { added.removeFromSuperlayer() }
        ScaleKeeper.shared.setNeedsComposeApply(host)
        ScaleKeeper.shared.apply()
        #expect(added.contentsScale == demo.renderScale, "the compose walk left a new layer at scale \(added.contentsScale)")
    }
}
