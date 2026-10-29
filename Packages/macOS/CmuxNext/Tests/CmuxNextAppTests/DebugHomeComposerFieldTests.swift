#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import MessagesLabHome
import Testing

/// `debug.home.drive {action: field}` reads what the Home composer's message box holds, so a journey
/// judges the person's typed text from the app, not from text recognition of light grey pixels
/// (v2.2.4-opt gate: scripted-newtab-keeps-person-keys failed only on its OCR; handoff/v224-gate-triage.md).
/// The read is record only: it never moves the caret, the selection, the text or the keyboard.
@MainActor @Suite(.serialized) struct DebugHomeComposerFieldTests {
    private struct Home {
        let window: NSWindow
        let store: HomeStore
        let view: HomeNativeTranscriptView
        let blobs: URL
        var field: NSTextView? { view.primaryInput as? NSTextView }
        func close() {
            view.stop()
            store.stop()
            try? FileManager.default.removeItem(at: blobs)
        }
    }

    private func home() async throws -> Home {
        let source = MockHomeSource(options: .immediate)
        let blobs = FileManager.default.temporaryDirectory.appendingPathComponent("home-field-\(UUID().uuidString)", isDirectory: true)
        let store = HomeStore(source: source, blobCacheDirectory: blobs)
        store.start()
        let inbox = try await source.inbox()
        let chief = await source.chief.id
        let id = try #require((inbox.conversations.first { $0.participants.contains { $0.id == chief } } ?? inbox.conversations.first)?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id, deadlines: linklessDeadlines())
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        return Home(window: window, store: store, view: view, blobs: blobs)
    }

    @Test func theReadGivesWhatThePersonTyped() async throws {
        let home = try await home()
        defer { home.close() }
        let field = try #require(home.field)
        #expect(home.window.makeFirstResponder(field))
        field.insertText("keep-987363", replacementRange: field.selectedRange())
        field.insertText("-more-987363", replacementRange: field.selectedRange())
        let read = try #require(DebugHomeNativeFixture.composerField(of: home.view))
        #expect(read.text == "keep-987363-more-987363")
        #expect(read.focused)
    }

    @Test func theReadChangesNothing() async throws {
        let home = try await home()
        defer { home.close() }
        let field = try #require(home.field)
        field.insertText("abc", replacementRange: field.selectedRange())
        field.setSelectedRange(NSRange(location: 1, length: 1))
        let responder = home.window.firstResponder
        let read = try #require(DebugHomeNativeFixture.composerField(of: home.view))
        #expect(read.text == "abc")
        #expect(field.string == "abc")
        #expect(field.selectedRange() == NSRange(location: 1, length: 1))
        #expect(home.window.firstResponder === responder)
    }
}
#endif
