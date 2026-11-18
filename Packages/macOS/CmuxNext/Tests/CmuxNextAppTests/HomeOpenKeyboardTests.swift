import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
@testable import MessagesLabHome
import CmuxNextTestSupport
import Testing

/// Home's message box takes the keyboard on an open made before it exists (a launch opens Home's page before its
/// first page arrives, and before the page is in a window): once installed, unless the person put the keyboard in
/// another text field meanwhile. A bare launch's fleet run (b44d23c2) showed 6 of 10 launches whose box never took
/// the keyboard, so the first thing a person typed went nowhere.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeOpenKeyboardTests {
    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    /// A Home whose first page waits (`source.hold()`), and its window; the view is not in the window yet.
    private func home() async throws -> (HomeStore, GatedHomeSource, NSWindow, NSView, HomeNativeTranscriptView) {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 20
        let source = GatedHomeSource(MockHomeSource(options: options))
        let store = HomeStore(source: source)
        store.start()
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        window.contentView = container
        window.orderFrontRegardless()
        source.hold()
        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        return (store, source, window, container, view)
    }

    private func firstPage(_ store: HomeStore, _ source: GatedHomeSource, _ window: NSWindow) async {
        source.release()
        await until { !store.transcript(for: Self.conversation).isEmpty }
        await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        await settle()
    }

    /// The open comes while the page is not in a window yet (Home's page is made before the launch's window shows it).
    @Test func anOpenBeforeTheWindowTakesTheKeyboardOnceInstalled() async throws {
        let (store, source, window, container, view) = try await home()
        defer { view.stop(); store.stop(); window.closeAfterTest() }
        view.takeKeyboardOnOpen()
        container.addSubview(view)
        await until { source.waiting > 0 }
        await firstPage(store, source, window)
        #expect(window.firstResponder === view.primaryInput, "the message box has the keyboard: \(String(describing: window.firstResponder))")
    }

    /// The open waits for the box, and meanwhile a pane focus puts the keyboard on Home's own view (its keyboard
    /// target before the box exists): the box still takes it once installed.
    @Test func anOpenTakesTheKeyboardFromHomesOwnView() async throws {
        let (store, source, window, container, view) = try await home()
        defer { view.stop(); store.stop(); window.closeAfterTest() }
        container.addSubview(view)
        await until { source.waiting > 0 }
        view.takeKeyboardOnOpen()
        window.makeFirstResponder(view.transcript)
        #expect(window.firstResponder === view.transcript)
        await firstPage(store, source, window)
        #expect(window.firstResponder === view.primaryInput, "the message box has the keyboard: \(String(describing: window.firstResponder))")
    }

    /// The person clicked another text field before the box existed: it keeps the keyboard.
    @Test func aFieldThePersonChoseKeepsTheKeyboard() async throws {
        let (store, source, window, container, view) = try await home()
        defer { view.stop(); store.stop(); window.closeAfterTest() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        container.addSubview(view)
        container.addSubview(field)
        await until { source.waiting > 0 }
        view.takeKeyboardOnOpen()
        window.makeFirstResponder(field)
        await firstPage(store, source, window)
        #expect(window.firstResponder !== view.primaryInput, "the box took the keyboard from the person's field")
        #expect((window.firstResponder as? NSText)?.delegate === field, "the field keeps it: \(String(describing: window.firstResponder))")
    }
}
