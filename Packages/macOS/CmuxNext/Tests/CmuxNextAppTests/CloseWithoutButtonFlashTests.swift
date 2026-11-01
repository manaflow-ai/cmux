import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// Close Window (Ctrl-Cmd-W, the menu) and the close key of a window that closes as a whole (Settings, Page Info,
/// a browser popup) must close in their own turn. They called `NSWindow.performClose(_:)`, which "simulates the
/// user clicking the close button by momentarily highlighting the button": `-[NSButtonCell performClick:]` runs a
/// nested event-tracking run loop to draw the highlight, about 100 ms on the key turn (v2.2.4-opt on cmux17:
/// `debug.action_budget` closeWindow 100.7 ms, outcome `nested`; the whole-stack sample has `performClick:` ->
/// `nextEventMatchingMask`, with Chromium pump passes inside it). Chrome closes a window from a key or a script
/// with no button highlight (`BrowserView::Close`, `views::Widget::Close`).
///
/// The highlight draws only on a visible window, so these tests need a display (a console session): a run with
/// no screen skips them, and a window that does not come on screen fails its precondition, never passes.
@Suite(.serialized, .closesItsWindows, .enabled(if: NSScreen.main != nil, "the close button flashes only on a display"))
@MainActor struct CloseWithoutButtonFlashTests {
    /// Counts run loop entries on the main run loop (any common mode, event tracking included) while `body` runs.
    static func nestedRunLoops(during body: () -> Void) -> Int {
        var entries = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue, true, 0) { _, _ in entries += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        body()
        return entries
    }

    /// Puts `window` on the main screen (the app stays inactive) with its close button shown and enabled.
    static func onScreen(_ window: NSWindow) throws {
        let screen = try #require(NSScreen.main)
        window.setFrame(NSRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 60, width: 700, height: 500), display: true)
        window.orderFrontRegardless()
        try #require(window.isVisible, "the window did not come on screen")
        let button = try #require(window.standardWindowButton(.closeButton), "the window has no close button")
        try #require(!button.isHidden && button.isEnabled, "the close button is hidden or off")
    }

    /// The close key of a closable window with no owner and no kind, through the registry's key window route as
    /// the app installs it (`WindowKeyTable`'s `.closeWindow`), with the person's close action.
    @Test func theCloseKeyOfAPlainWindowClosesItWithNoNestedRunLoop() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        WindowKeyTable.install(services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try Self.onScreen(window)
        services.keyWindowSource = { [window] in window }

        var ran = false
        let entries = Self.nestedRunLoops { ran = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)) }

        #expect(ran, "the key window route did not run the close")
        #expect(entries == 0, "the close key ran \(entries) nested run loop(s) on the key turn (the close button's flash)")
        #expect(!window.isVisible, "the window did not close in the key's turn")
    }

    /// Close Window on the app's own window (the action the menu and Ctrl-Cmd-W run), on a real daemon session.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func closeWindowClosesTheMainWindowWithNoNestedRunLoop() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            try Self.onScreen(window)

            var ran = false
            let entries = Self.nestedRunLoops { ran = services.registry.perform("closeWindow", invocation: ActionInvocation(origin: .user)) }

            #expect(ran, "Close Window did not run")
            #expect(entries == 0, "Close Window ran \(entries) nested run loop(s) on the key turn (the close button's flash)")
            // The person's close may fade first (WindowCloseMotion); the window is gone when it ends.
            try await PinnedPageTests.until({ !window.isVisible }, within: .seconds(5))
        }
    }

    /// A sheet on the window (a folder picker, a confirmation) keeps it open, as AppKit's disabled close button
    /// does while a sheet is attached: the close key never closes a window under its sheet.
    @Test func theCloseKeyLeavesAWindowWithASheetOpen() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        WindowKeyTable.install(services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            if window.attachedSheet != nil { window.endSheet(sheet) }
            sheet.closeAfterTest()
            window.close()
        }
        try Self.onScreen(window)
        window.beginSheet(sheet)
        try #require(window.attachedSheet === sheet, "AppKit attached no sheet")
        services.keyWindowSource = { [window] in window }

        _ = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))

        #expect(window.isVisible, "the window closed under its sheet")
    }
}
