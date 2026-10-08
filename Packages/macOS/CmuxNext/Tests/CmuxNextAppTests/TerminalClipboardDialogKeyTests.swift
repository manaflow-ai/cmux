import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// A clipboard-read dialog blocks only its terminal's tab. Escape typed
/// while that tab holds the window's keyboard denies the read, also when
/// the key reaches the window under the dialog's overlay: the overlay did
/// not take the keyboard (cmux was not active when the read came, the
/// person clicked the window, or automation sent the key to the window).
/// Through the app-wide key interceptor that `CmuxApplication.sendEvent`
/// (and `debug.key`) runs for every key-down, on a real window with the
/// real overlay host and the service's own dialog `ask`.
@MainActor @Suite(.serialized) struct TerminalClipboardDialogKeyTests {
    final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A window with two tabs side by side, each with a view that can hold
    /// the keyboard, and one clipboard-read dialog scoped to the left tab.
    @MainActor final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let right = NSView(frame: NSRect(x: 400, y: 0, width: 400, height: 600))
        let leftTerminal = Focusable(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let rightTerminal = Focusable(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        var answers: [Bool] = []
        private var close: (() -> Void)?

        init() throws {
            window.isReleasedWhenClosed = false
            let root = try #require(window.contentView)
            root.addSubview(left)
            root.addSubview(right)
            left.addSubview(leftTerminal)
            right.addSubview(rightTerminal)
            let ask = TerminalClipboardReadService.dialogAsk(center: .shared) { [left] _ in
                .init(terminalTitle: "build", scope: .tab(left))
            }
            let prompt = ClipboardReadPrompt(requestID: "r1", terminalID: "term_1", location: .standard,
                                             host: ClipboardReadHost(kind: .local))
            close = ask(prompt) { [unowned self] in answers.append($0) }
        }

        var open: [CmuxDialogCenter.Record] {
            CmuxDialogCenter.shared.records.filter { $0.spec.identifier == ClipboardReadStrings.identifier }
        }

        func escape() -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                         charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
            return router.interceptKeyDown(event, in: window)
        }

        /// Leaves the shared center as it was.
        func tearDown() {
            close?()
            window.close()
        }
    }

    @Test func escapeInTheAskingTabDeniesTheRead() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(f.open.count == 1)
        #expect(f.window.makeFirstResponder(f.leftTerminal), "the asking terminal has the window's keyboard")
        #expect(f.escape(), "Escape is the dialog's")
        #expect(f.answers == [false], "Escape answers Deny")
        #expect(f.open.isEmpty, "and the dialog closes")
    }

    @Test func escapeInAnotherTabLeavesTheQuestionOpen() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(f.window.makeFirstResponder(f.rightTerminal), "another tab has the keyboard")
        #expect(!f.escape(), "Escape goes on to that tab")
        #expect(f.answers.isEmpty && f.open.count == 1, "the asking tab's question stays")
    }

    /// nxdog46-v1: a click on the sidebar moves the window's keyboard out of
    /// every tab; Escape then still answers the focused pane's dialog. A
    /// real window, its focus coordinator and the app-wide key interceptor.
    @Test func escapeAfterASidebarClickDeniesTheFocusedPanesRead() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        defer { main.teardown() }
        await BrowserTabTests.settle { main.content != nil }
        let content = try #require(main.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        let shell = try #require(main.window)
        let tab = Focusable(frame: pane.view.bounds)
        pane.view.addSubview(tab)
        var answers: [Bool] = []
        let ask = TerminalClipboardReadService.dialogAsk(center: .shared) { _ in .init(terminalTitle: "build", scope: .tab(tab)) }
        let close = ask(ClipboardReadPrompt(requestID: "r2", terminalID: "term_2", location: .standard,
                                            host: ClipboardReadHost(kind: .local))) { answers.append($0) }
        defer { close() }
        main.focus.send(.focusTarget(.sidebar(keyboard: false), source: .mouse))
        shell.makeFirstResponder(nil)
        #expect(main.focus.state.resolved == .sidebar, "the sidebar has the window's keyboard")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: shell.windowNumber, context: nil, characters: "\u{1B}",
                                     charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        #expect(services.keyRouter.interceptKeyDown(event, in: shell), "Escape is the focused pane's dialog")
        #expect(answers == [false], "Escape answers Deny")
        withExtendedLifetime((services, ask)) {}
    }

    /// A Chromium page is a child window of the cmux window and is key while
    /// the page has the keyboard. Escape that reaches it answers the dialog
    /// over the focused pane's tab (the dialog's overlay did not take the
    /// keyboard), as in a terminal tab.
    @Test func escapeInTheFocusedPanesPageWindowDeniesItsDialog() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        defer { main.teardown() }
        await BrowserTabTests.settle { main.content != nil }
        let content = try #require(main.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        let shell = try #require(main.window)
        let tab = NSView(frame: pane.view.bounds)
        pane.view.addSubview(tab)
        // The page window, as the Chromium fork adds it.
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        shell.addChildWindow(page, ordered: .above)
        defer {
            shell.removeChildWindow(page)
            page.close()
        }
        var answers: [Bool] = []
        let ask = TerminalClipboardReadService.dialogAsk(center: .shared) { _ in .init(terminalTitle: "page", scope: .tab(tab)) }
        let close = ask(ClipboardReadPrompt(requestID: "r3", terminalID: "term_3", location: .standard,
                                            host: ClipboardReadHost(kind: .local))) { answers.append($0) }
        defer { close() }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: page.windowNumber, context: nil, characters: "\u{1B}",
                                     charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        #expect(services.keyRouter.interceptKeyDown(event, in: page), "Escape in the page window is the dialog's")
        #expect(answers == [false], "Escape answers Deny")
        withExtendedLifetime((services, ask)) {}
    }
}
