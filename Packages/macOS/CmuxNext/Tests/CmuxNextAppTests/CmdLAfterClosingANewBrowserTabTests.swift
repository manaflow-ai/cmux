import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Lawrence 2026-11-20 ("cmd l not working on my computer", a 7 s video): Home, the Chief dock on the left and a
/// browser page in the pane on its right. Shift-Cmd-L opened a New Browser Tab (its omnibar took the keyboard), Cmd-W
/// closed it, and the page's tab showed again; then Cmd-L, pressed five times, never focused or selected the page's
/// address bar. Each press goes through the app's key path (the key router, then the window), as a person's does. After
/// the close, Cmd-L puts the keyboard in the address bar of the browser the person is in, with its URL selected.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct CmdLAfterClosingANewBrowserTabTests {
    /// Where the page's browser is: a pane of an ordinary workspace, or the pane right of Home's Chief dock.
    enum Place: String, CaseIterable, Sendable { case workspacePane, homeRightPane }

    private static let codes: [Character: UInt16] = ["l": 37, "w": 13]
    private static let pageURL = "https://example.com/cmd-l"

    /// A key-down as `CmuxApplication.sendEvent` delivers it to a window that is not key (the test's): the router first.
    private static func press(_ character: Character, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow, router: KeyRouter) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                                  isARepeat: false, keyCode: codes[character] ?? 0))
        if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    private static func bar(_ pane: PaneController) -> AddressBarView? {
        if case .browser(let entry)? = pane.currentContent { entry.chrome?.addressBar } else { nil }
    }

    /// The page's browser tab in `pane`, as the daemon made it (not a stand-in).
    private static func pageTab(_ pane: PaneController) -> TabModel? {
        pane.pane.tabs.first { $0.kind == .browser && !ProvisionalTab.isProvisional($0.id) && $0.url?.hasPrefix(pageURL) == true }
    }

    @Test(arguments: Place.allCases)
    func cmdLFocusesThePagesAddressBarAfterANewBrowserTabCloses(place: Place) async throws {
        // A held key runs again through the same key path as a typed one (the test window is never key).
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let router = services.keyRouter
            // On screen, never key: the pane draws its frames.
            window.orderFrontRegardless()

            // The pane the page shows in: the window's focused pane, or a column right of Home's dock.
            let pane: PaneController
            switch place {
            case .workspacePane:
                pane = try #require(controller.focusedPane)
            case .homeRightPane:
                let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
                var terminal = ActionInvocation(origin: .user)
                terminal.opensTerminal = true
                #expect(services.registry.perform("splitRight", invocation: terminal))
                try await PasswordManagerRouteTests.until({
                    HomeSplitKeysTests.panes(home).count == 2
                        && HomeSplitKeysTests.panes(home).last.map { $0.handle.rawValue < ProvisionalPane.firstHandle } == true
                }, report: { "\(HomeSplitKeysTests.panes(home).count) panes in Home" })
                let right = try #require(HomeSplitKeysTests.panes(home).last)
                pane = try #require(services.paneController(for: right))
            }
            _ = try await connection.newFrontendBrowserTab(url: Self.pageURL, engine: .webkit, in: pane.pane.handle, activate: true)
            try await PasswordManagerRouteTests.until({ Self.pageTab(pane) != nil }, report: { "the page's tab: \(pane.pane.tabs.map { "\($0.kind) \($0.id)" })" })
            let page = try #require(Self.pageTab(pane))
            pane.select(StripTabID(page.id))
            // The person is on the page: the pane has the focus, its content the keyboard.
            controller.focus.send(.focusPane(pane.paneKey, source: .intent))
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return pane.currentTabKey == page.id && Self.bar(pane) != nil
                && controller.focusedPane === pane && Self.bar(pane)?.isEditing == false },
                report: { "the page shows with the keyboard off its omnibar: tab \(pane.currentTabKey ?? "none"), focus \(controller.focus.state.resolved)" })

            // Shift-Cmd-L: a New Browser Tab in the pane; its omnibar takes the keyboard.
            #expect(services.registry.perform("openBrowser.webkit", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({
                pane.showSelected()
                guard let shown = pane.currentTabKey, shown != page.id, !ProvisionalTab.isProvisional(shown) else { return false }
                return Self.bar(pane)?.editsAsFirstResponder == true
            }, report: { "the new tab: shown \(pane.currentTabKey ?? "none"), omnibar editing \(Self.bar(pane)?.isEditing == true)" })
            let newTab = try #require(pane.currentTabKey)
            let coordinator = router.creationInputCoordinator
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, report: { "the new tab's creation hold never ended" })

            // Cmd-W: the new tab closes; the page's tab shows again.
            try Self.press("w", .command, in: window, router: router)
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return !pane.pane.tabs.contains { $0.id == newTab } && pane.currentTabKey == page.id },
                                                      report: { "after Cmd-W: tabs \(pane.pane.tabs.map(\.id)), shown \(pane.currentTabKey ?? "none")" })

            // Cmd-L: the page's address bar takes the keyboard, its URL selected. Every press, as the person pressed it again.
            for press in 1...2 {
                try Self.press("l", .command, in: window, router: router)
                try await PasswordManagerRouteTests.until({ pane.showSelected(); return Self.bar(pane)?.editsAsFirstResponder == true && Self.bar(pane)?.debugAllSelected == true },
                                                          within: .seconds(5), report: {
                    "Cmd-L \(press) after the close: focus \(controller.focus.state.resolved), focused pane \(controller.focusedPane?.paneKey ?? "none") (page's \(pane.paneKey)), "
                        + "omnibar editing \(Self.bar(pane)?.isEditing == true), first responder \(String(describing: window.firstResponder)), "
                        + "creation hold \(coordinator.isHolding(in: window)), last hold end \(String(describing: coordinator.lastHoldEnd(in: window)))"
                })
                #expect(controller.focusedPane === pane, "Cmd-L \(press) moved the focus off the page's pane")
            }
        }
    }

    /// The same Home, with the keyboard in the Chief dock: the dock has no address bar, so Cmd-L puts the keyboard in
    /// the address bar of the browser beside it, its URL selected, and opens nothing in the dock.
    @Test func cmdLInHomesChatDockFocusesTheAddressBarOfTheBrowserBesideIt() async throws {
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let router = services.keyRouter
            window.orderFrontRegardless()

            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PasswordManagerRouteTests.until({
                HomeSplitKeysTests.panes(home).count == 2
                    && HomeSplitKeysTests.panes(home).last.map { $0.handle.rawValue < ProvisionalPane.firstHandle } == true
            }, report: { "\(HomeSplitKeysTests.panes(home).count) panes in Home" })
            let dockModel = try #require(HomeSplitKeysTests.panes(home).first)
            let paneModel = try #require(HomeSplitKeysTests.panes(home).last)
            let dock = try #require(services.paneController(for: dockModel))
            let pane = try #require(services.paneController(for: paneModel))
            _ = try await connection.newFrontendBrowserTab(url: Self.pageURL, engine: .webkit, in: pane.pane.handle, activate: true)
            try await PasswordManagerRouteTests.until({ Self.pageTab(pane) != nil }, report: { "the page's tab: \(pane.pane.tabs.map { "\($0.kind) \($0.id)" })" })
            let page = try #require(Self.pageTab(pane))
            pane.select(StripTabID(page.id))
            let dockTabs = dock.pane.tabs.map(\.id)

            // The person is in the Chief dock: its pane has the focus.
            controller.focus.send(.focusPane(dock.paneKey, source: .intent))
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return pane.currentTabKey == page.id && Self.bar(pane) != nil
                && controller.focusedPane === dock && Self.bar(pane)?.isEditing == false },
                report: { "the dock has the focus, the page shows beside it: tab \(pane.currentTabKey ?? "none"), focus \(controller.focus.state.resolved)" })

            try Self.press("l", .command, in: window, router: router)
            try await PasswordManagerRouteTests.until({ pane.showSelected(); return Self.bar(pane)?.editsAsFirstResponder == true && Self.bar(pane)?.debugAllSelected == true },
                                                      within: .seconds(5), report: {
                "Cmd-L in the dock: focus \(controller.focus.state.resolved), focused pane \(controller.focusedPane?.paneKey ?? "none") (page's \(pane.paneKey), dock's \(dock.paneKey)), "
                    + "omnibar editing \(Self.bar(pane)?.isEditing == true), first responder \(String(describing: window.firstResponder)), dock tabs \(dock.pane.tabs.map(\.id))"
            })
            #expect(controller.focusedPane === pane, "Cmd-L in the dock did not move the focus to the browser beside it")
            #expect(dock.pane.tabs.map(\.id) == dockTabs, "Cmd-L in the dock opened a tab there: \(dock.pane.tabs.map(\.id))")
        }
    }
}
