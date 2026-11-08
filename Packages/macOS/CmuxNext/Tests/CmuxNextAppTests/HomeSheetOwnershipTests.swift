import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextTestSupport
import Testing

/// cmux#38175: on cmux NEXT the New Chief dialog never made a Chief. Home's callers
/// (`TopHomePageView.presentNewChief`, Invite, Message Requests, Invite to Team) hand the sheet to
/// ``HomeSheetPresenter`` and keep no reference; the window overlay holds only the sheet's view.
/// The sheet was released as it showed, so its name field had no delegate (Create never enabled
/// while the person typed) and its buttons had no target. These tests present a sheet the way the
/// app does, with no reference kept, and use it through its real field editor and button.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeSheetOwnershipTests {
    @Test func aNewChiefSheetNobodyHoldsCreatesTheTypedChiefAndOpensIt() async throws {
        let window = Self.window()
        defer { Self.close(window) }
        let (asked, ask) = AsyncStream<(String, ChiefBackend)>.makeStream()
        let (finishes, finish) = AsyncStream<ConversationID?>.makeStream()
        weak var shown: HomeNewChiefSheet?
        let (field, create) = Self.presentNewChief(over: window, ask: ask, finish: finish) { shown = $0 }

        try #require(shown != nil, "the presented sheet was released while it shows")
        let editor = try #require(field.window?.firstResponder as? NSTextView, "the name field does not have the keyboard")
        editor.insertText("Research", replacementRange: editor.selectedRange())
        #expect(field.stringValue == "Research")
        try #require(create.isEnabled, "typing a name does not enable Create")
        try #require(create.target != nil, "Create has no target: its sheet is gone")

        create.performClick(nil)
        var askedIterator = asked.makeAsyncIterator()
        let request = try #require(await askedIterator.next(), "Create did not run the create")
        #expect(request.0 == "Research")
        #expect(request.1 == .claude)
        var finishIterator = finishes.makeAsyncIterator()
        let opened = await finishIterator.next()
        #expect(opened == .some(ConversationID("conv_research")), "the new Chief's conversation is not opened")
        #expect(WindowOverlayHost.existingHost(for: window)?.presentedHandles.isEmpty ?? true, "the dialog stayed up")
    }

    @Test func aSheetNobodyHoldsCancelsWithItsButton() async throws {
        let window = Self.window()
        defer { Self.close(window) }
        let (_, ask) = AsyncStream<(String, ChiefBackend)>.makeStream()
        let (finishes, finish) = AsyncStream<ConversationID?>.makeStream()
        var cancel: NSButton?
        _ = Self.presentNewChief(over: window, ask: ask, finish: finish) { cancel = $0.cancelButton }

        let button = try #require(cancel)
        try #require(button.target != nil, "Cancel has no target: its sheet is gone")
        button.performClick(nil)
        var iterator = finishes.makeAsyncIterator()
        let finished = await iterator.next()
        #expect(finished == .some(nil))
        #expect(WindowOverlayHost.existingHost(for: window)?.presentedHandles.isEmpty ?? true, "Cancel left the dialog up")
    }

    /// Presents New Chief as `TopHomePageView.presentNewChief` does: the sheet is a local that
    /// goes out of scope here. The autorelease pool drains before this returns, as the app's run
    /// loop does after the menu action, so only what really owns the sheet keeps it (without it,
    /// AppKit's autoreleases kept a released sheet alive until the create's first await).
    /// Returns its name field and Create button.
    private static func presentNewChief(
        over window: NSWindow,
        ask: AsyncStream<(String, ChiefBackend)>.Continuation,
        finish: AsyncStream<ConversationID?>.Continuation,
        inspect: (HomeNewChiefSheet) -> Void
    ) -> (NSTextField, NSButton) {
        autoreleasepool {
            let sheet = HomeNewChiefSheet()
            sheet.onCreate = { name, backend in
                ask.yield((name, backend))
                return .opened(ConversationID("conv_research"))
            }
            sheet.onFinish = { finish.yield($0) }
            HomeSheetPresenter().present(sheet, over: window)
            inspect(sheet)
            return (sheet.name, sheet.primaryButton)
        }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func close(_ window: NSWindow) {
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.close()
        panel?.close()
    }
}
