import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHomeEngine
@testable import CmuxNextSidebar
import Foundation
import Testing

/// MW-1 (Lawrence 2026-10-28: "keyboard shortcuts dont work, and clicking on home/workspaces might
/// bring me to the wrong window. we need to completely eliminate this error class"). Two windows:
/// window A holds the store's Home and shows a workspace of its own; window B is the one the person
/// works in. Cmd-1 ("Select the first sidebar item", here Home) typed in B, or a click on B's Home
/// item, shows B's own Home in B and leaves A as it was. The VIDEO EXTRA multi-window journey saw
/// window A switch to Home instead (dogfood 2f3a5721c39) or nothing change (feat 0d19fe6).
///
/// Each entry runs as the app runs it: the input's dispatch has window B as its origin
/// (`WindowManager.dispatching(eventFrom:_:)`, what `CmuxApplication.sendEvent` does), and the key
/// window record names another window (window A: the record lags after Cmd-Tab, or the app is not
/// active), so only the window the input came from can say where it acts.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarFirstItemInItsWindowTests {
    enum Entry: String, CaseIterable, CustomTestStringConvertible {
        /// Cmd-1 through the app's key router, in window B's dispatch.
        case cmdOneKey
        /// A click on window B's Home item (the sidebar's activate intent), in window B's dispatch.
        case homeItemClick
        /// The Cmd-1 action run by name for window B (the palette, the menu): no event, B is the active window.
        case selectNumberAction

        var testDescription: String { rawValue }
    }

    @Test(arguments: Entry.allCases)
    func theFirstSidebarItemShowsInTheWindowItWasAskedIn(_ entry: Entry) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let keyWindow = services.keyWindowSource
            defer { services.keyWindowSource = keyWindow }
            let (windowA, homeA) = try await HomeSplitKeysTests.showHome(services, connection)
            // Window A moves on to a workspace of its own; the store's Home stays in it.
            services.keyWindowSource = { [weak windowA] in windowA?.window }
            let ownA = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "mw1-first-window"),
                                                                  into: windowA.state.id)
            try await PinnedPageTests.until({ services.workspace(id: ownA) != nil }, within: .seconds(30))
            services.windows.show(workspaceID: ownA, in: windowA.state, from: .thisWindow)
            try await PinnedPageTests.until({ windowA.state.workspaceID == ownA && windowA.state.page == nil },
                                            report: { "window A shows \(windowA.state.workspaceID ?? "nil")" })

            let idB = services.windows.newWindow()
            try await PinnedPageTests.until({
                services.windows.controller(for: idB) != nil && !services.windows.registry.members(of: idB).isEmpty
            }, within: .seconds(60), report: { "windows \(services.windows.controllers.map(\.state.id))" })
            let windowB = try #require(services.windows.controller(for: idB))
            try await PinnedPageTests.until({ windowB.state.workspaceID != nil }, within: .seconds(30))
            services.keyWindowSource = { [weak windowB] in windowB?.window }
            try await PinnedPageTests.until({ SidebarCmdNumberTwiceTests.topItemsSettled(windowB, services) }, within: .seconds(30), report: {
                "window B's top items never settled: " + SidebarCmdNumberTwiceTests.report(windowB, services, picked: nil, orderAtPick: nil)
            })
            // Cmd-1 is Home here (the default numbering counts the top items first).
            let modelB = windowB.sidebar.model
            let first = try #require(modelB.itemOrder.pick(1, SidebarNavigation.settings(services)), "Cmd-1 picks nothing in window B")
            guard case .topItem(let homeItem) = first, let ref = modelB.layout.item(homeItem)?.ref ?? modelB.listedItem(homeItem)?.ref,
                  TopPageRoute.route(for: ref) == .home else {
                Issue.record("window B's first sidebar item is \(first), not Home")
                return
            }
            let shownB = windowB.state.workspaceID
            let (shownA, pageA, membersA) = (windowA.state.workspaceID, windowA.state.page, services.windows.registry.members(of: windowA.state.id))
            @MainActor func report() -> String {
                let owner = { (id: String?) in id.flatMap { services.windows.registry.value.owner(of: $0) } ?? "none" }
                return "window A shows \(windowA.state.workspaceID ?? "nil") (was \(shownA ?? "nil")), page \(String(describing: windowA.state.page)), "
                    + "members \(services.windows.registry.members(of: windowA.state.id)) (were \(membersA)); "
                    + "window B shows \(windowB.state.workspaceID ?? "nil") (was \(shownB ?? "nil"), owner \(owner(windowB.state.workspaceID))), "
                    + "B selects \(String(describing: SidebarNavigation.current(in: windowB, services))); store Home \(homeA.id) in \(owner(homeA.id)); "
                    + "window Homes \(services.daemon.store.workspaces.filter(\.isWindowHome).map { "\($0.id) in \(owner($0.id))" })"
            }

            // The key window record names window A from here on: B's input must not depend on it.
            services.keyWindowSource = { [weak windowA] in windowA?.window }
            let windowNS = try #require(windowB.window)
            switch entry {
            case .cmdOneKey:
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNS.windowNumber,
                                                          context: nil, characters: "1", charactersIgnoringModifiers: "1",
                                                          isARepeat: false, keyCode: 18))
                let taken = services.windows.dispatching(eventFrom: windowNS) { services.keyRouter.interceptKeyDown(event, in: windowNS) }
                #expect(taken, "the key router did not take Cmd-1 in window B")
            case .homeItemClick:
                services.windows.dispatching(eventFrom: windowNS) { windowB.sidebar.handle(.activateItem(homeItem)) }
            case .selectNumberAction:
                services.keyWindowSource = { [weak windowB] in windowB?.window }
                #expect(services.registry.perform("selectWorkspaceByNumber", argument: "1"))
                services.keyWindowSource = { [weak windowA] in windowA?.window }
            }

            // Window B shows its own Home, selected in its sidebar; window A is as it was.
            try await PinnedPageTests.until({
                windowB.state.workspaceID.flatMap(services.workspace(id:))?.isAnyHome == true
                    && modelB.itemOrder.stop(for: SidebarNavigation.current(in: windowB, services)) == first
            }, within: .seconds(60), report: { "\(entry) in window B did not show Home there: " + report() })
            let homeB = try #require(windowB.state.workspaceID)
            #expect(homeB != homeA.id, "window B shows window A's Home: \(report())")
            #expect(services.windows.registry.value.owner(of: homeB) == idB, "window B's Home is not in window B: \(report())")
            #expect(windowA.state.workspaceID == shownA && windowA.state.page == pageA, "\(entry) in window B changed window A: \(report())")
            #expect(services.windows.registry.members(of: windowA.state.id) == membersA, "window A's workspaces changed: \(report())")
        }
    }
}
