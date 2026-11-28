import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A page's `prompt()` with in-tree pages on (live step 220203899a25, prompts.prompt_keys): the cmux dialog showed, but
/// its text field never took the keyboard, so typed keys went to the dialog's key handler (or the page) and reached the
/// field only after a click on it. Chrome's prompt has the keyboard in its field the moment it shows.
///
/// In tree the dialog is an overlay on the cmux window itself, so its field takes the keys through the window's
/// responder gate (`ShellWindow.makeFirstResponder`). The gate's G1 rule (`UnseenKeyboardGuard`) refuses a move,
/// outside an input event, from a view that shows to one that does not, and the card had not laid out yet when it
/// asked: its Auto Layout frame was still zero, so the field inside it had no visible rect and read as unseen.
/// The page (where the person typed) kept the keys. With the mode off the overlay is its own panel, which has no gate.
@MainActor @Suite(.serialized, .closesItsWindows) struct InTreePromptKeyboardTests {
    /// The page's view in its tab: where the person typed before the page asked.
    private final class PageView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func aPromptsFieldHasTheKeyboardTheMomentItShowsInTree() throws {
        _ = NSApplication.shared
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try #require(InTreePages.shared.isActive)
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["itp-1"]))
        let window = try #require(controller.window)
        defer {
            CmuxDialogCenter.shared.dismissAll()
            for controller in services.windows.controllers { controller.window?.close() }
            AppHarnessWindows.closeThoseThisTestOpened()
        }
        let content = try #require(window.contentView)
        let tab = NSView(frame: content.bounds.insetBy(dx: 40, dy: 40))
        let page = PageView(frame: tab.bounds)
        tab.addSubview(page)
        content.addSubview(tab, positioned: .below, relativeTo: content.subviews.first)
        window.makeFirstResponder(page)
        try #require(window.firstResponder === page, "the page did not take the keyboard first")
        let spec = CmuxDialogSpec(usesTransientMaterial: true, title: "example.com says", lines: ["in-tree prompt"],
                                  fields: [.text("text", initial: "")],
                                  buttons: [CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel),
                                            CmuxDialogButton(id: "ok", title: "OK", role: .default)],
                                  identifier: "browser.dialog.javascript")
        let id = CmuxDialogCenter.shared.present(spec, in: .tab(tab)) { _ in }
        let dialog = try #require(CmuxDialogCenter.shared.dialog(id)?.view, "the prompt showed no dialog")
        let responder = window.firstResponder as? NSView
        let field = responder.flatMap { ($0 as? NSTextView)?.delegate as? NSTextField ?? $0 as? NSTextField }
        #expect(field?.isDescendant(of: dialog) == true,
                "the prompt's field did not have the keyboard when it showed: \(responder.map { String(describing: type(of: $0)) } ?? "nil") had it")
    }
}
