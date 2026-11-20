import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHomeEngine
@testable import CmuxNextSidebar
import CmuxNextSettings
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
///
/// MW-1b: window B opens two ways. `newWindow()` keeps it on window A's space; New Window as the
/// person runs it (Cmd-Shift-N, `newWindow`) opens it on a new space (spaces-overhaul-DESIGN.md rule
/// 3). On a new space B's own Home was made unpinned, so in the default space only: it joined B but
/// B's space never listed it, and Cmd-1 or Home showed nothing (VIDEO EXTRA probe, feat 35c4c3bd).
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarFirstItemInItsWindowTests {
    enum Entry: String, CaseIterable, CustomTestStringConvertible {
        /// Cmd-1 through the app's key router, in window B's dispatch.
        case cmdOneKey
        /// A click on window B's Home item (the sidebar's activate intent), in window B's dispatch.
        case homeItemClick
        /// A click on window B's Home item that runs after its click's dispatch, while the key window record names
        /// window A (cmux#37371: Home showed in window A, which came forward and switched the macOS Space).
        case homeItemClickAfterDispatch
        /// The Cmd-1 action run by name for window B (the palette, the menu): no event, B is the active window.
        case selectNumberAction
        /// Cmd-1 as the journey sends it (`debug.key` with `window` B) in an app that is not active: no
        /// window is key before or after the key, and the key has no event origin.
        case debugKeyInactiveApp
        /// Go to Home (`home.show`) from the palette or the menu, with window B active.
        case homeShowAction

        var testDescription: String { rawValue }
    }

    /// How window B opens.
    enum Opening: String, CaseIterable, CustomTestStringConvertible {
        /// `WindowManager.newWindow()`: on window A's space.
        case sameSpace
        /// New Window as the person runs it (Cmd-Shift-N, `newWindow`): on a new space.
        case newSpace
        /// Move Workspace to New Window (`moveWorkspaceToNewWindow`, the journey's set-up): a workspace of window A
        /// moves into a new window, which takes a space of its own (`WindowOwnSpace.give`).
        case movedWorkspace

        var testDescription: String { rawValue }
    }

    @Test(arguments: Entry.allCases, Opening.allCases)
    func theFirstSidebarItemShowsInTheWindowItWasAskedIn(_ entry: Entry, opening: Opening) async throws {
        let newSpace = opening != .sameSpace
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

            let before = Set(services.windows.controllers.map(\.state.id))
            switch opening {
            case .newSpace:
                // New Window as the person runs it: a new space (its personal state must be loaded for that).
                try await PinnedPageTests.until({ services.machines.local.store.personal.isLoaded }, within: .seconds(30))
                #expect(services.registry.perform("newWindow", invocation: ActionInvocation(origin: .user)))
            case .sameSpace:
                _ = services.windows.newWindow()
            case .movedWorkspace:
                let moving = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "mw1-moved"),
                                                                        into: windowA.state.id)
                try await PinnedPageTests.until({ services.windows.registry.value.owner(of: moving) == windowA.state.id }, within: .seconds(30))
                services.windows.show(workspaceID: ownA, in: windowA.state, from: .thisWindow)
                let move = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: moving), origin: .user)
                #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: move))
            }
            let opened = { services.windows.controllers.first { !before.contains($0.state.id) && !services.windows.registry.members(of: $0.state.id).isEmpty } }
            try await PinnedPageTests.until({ opened() != nil }, within: .seconds(60),
                                            report: { "windows \(services.windows.controllers.map(\.state.id))" })
            let windowB = try #require(opened())
            let idB = windowB.state.id
            // New Window's space: the window settles on it once the daemon mirrors the new room and its pin.
            try await PinnedPageTests.until({
                windowB.state.workspaceID != nil && (windowB.state.profileID != windowA.state.profileID) == newSpace
            }, within: .seconds(30), report: {
                let local = services.machines.local
                return "window B is on space \(windowB.state.profileID) showing \(windowB.state.workspaceID ?? "nil"), window A on "
                    + "\(windowA.state.profileID); spaces \(local.store.profileIDs), profiles-v1 \(local.supports(DaemonCapability.profiles.rawValue)), "
                    + "B lists \(services.windows.registry.members(of: idB))"
            })
            let roomB = windowB.state.profileID
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
            #expect(shownB.flatMap(services.workspace(id:))?.isAnyHome != true, "window B shows a Home before the input")
            let (shownA, pageA, membersA) = (windowA.state.workspaceID, windowA.state.page, services.windows.registry.members(of: windowA.state.id))
            @MainActor func report() -> String {
                let owner = { (id: String?) in id.flatMap { services.windows.registry.value.owner(of: $0) } ?? "none" }
                return "window A shows \(windowA.state.workspaceID ?? "nil") (was \(shownA ?? "nil")), page \(String(describing: windowA.state.page)), "
                    + "members \(services.windows.registry.members(of: windowA.state.id)) (were \(membersA)); "
                    + "window B shows \(windowB.state.workspaceID ?? "nil") (was \(shownB ?? "nil"), owner \(owner(windowB.state.workspaceID))), "
                    + "B selects \(String(describing: SidebarNavigation.current(in: windowB, services))); store Home \(homeA.id) in \(owner(homeA.id)); "
                    + "window Homes \(services.daemon.store.workspaces.filter(\.isWindowHome).map { "\($0.id) in \(owner($0.id))" })"
                    + "; window B's space \(windowB.state.profileID) (was \(roomB)), lists \(services.windows.registry.members(of: idB))"
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
            case .homeItemClickAfterDispatch:
                windowB.sidebar.handle(.activateItem(homeItem))
            case .selectNumberAction:
                services.keyWindowSource = { [weak windowB] in windowB?.window }
                #expect(services.registry.perform("selectWorkspaceByNumber", argument: "1"))
                services.keyWindowSource = { [weak windowA] in windowA?.window }
            case .homeShowAction:
                services.keyWindowSource = { [weak windowB] in windowB?.window }
                #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
                services.keyWindowSource = { [weak windowA] in windowA?.window }
            case .debugKeyInactiveApp:
                services.keyWindowSource = { nil }
                let reply = DebugKey.send(["key": .string("1"), "modifiers": .array([.string("cmd")]), "window": .string(idB)], services: services)
                #expect(reply["handled_by"]?.stringValue == "app", "debug.key Cmd-1 in window B: \(reply)")
            }

            // Window B shows its own Home, selected in its sidebar; window A is as it was.
            try await PinnedPageTests.until({
                windowB.state.workspaceID.flatMap(services.workspace(id:))?.isAnyHome == true
                    && modelB.itemOrder.stop(for: SidebarNavigation.current(in: windowB, services)) == first
            }, within: .seconds(60), report: { "\(entry) in window B did not show Home there: " + report() })
            let homeB = try #require(windowB.state.workspaceID)
            #expect(homeB != homeA.id, "window B shows window A's Home: \(report())")
            #expect(services.windows.registry.value.owner(of: homeB) == idB, "window B's Home is not in window B: \(report())")
            #expect(windowB.state.profileID == roomB, "Home moved window B off its space \(roomB): \(report())")
            #expect(windowA.state.workspaceID == shownA && windowA.state.page == pageA, "\(entry) in window B changed window A: \(report())")
            #expect(services.windows.registry.members(of: windowA.state.id) == membersA, "window A's workspaces changed: \(report())")
        }
    }
    /// cmux#37371: a tab row clicked in window B's sidebar (or in a workspace row's hover card) for a workspace window
    /// A lists shows that tab in window B, as a click on the workspace row does. It went to window A, which came
    /// forward and could switch the macOS Space. The key window record names window A, as after Cmd-Tab.
    @Test func aTabRowClickedInWindowBShowsTheTabInWindowB() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let keyWindow = services.keyWindowSource
            defer { services.keyWindowSource = keyWindow }
            let (windowA, _) = try await HomeSplitKeysTests.showHome(services, connection)
            services.keyWindowSource = { [weak windowA] in windowA?.window }
            let ownA = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "37371-tab-row"),
                                                                  into: windowA.state.id)
            let firstTab = { services.workspace(id: ownA)?.screens.flatMap(\.panes).flatMap(\.tabs).first?.id }
            try await PinnedPageTests.until({ firstTab() != nil && services.windows.registry.value.owner(of: ownA) == windowA.state.id },
                                            within: .seconds(30))
            services.windows.show(workspaceID: ownA, in: windowA.state, from: .thisWindow)
            let before = Set(services.windows.controllers.map(\.state.id))
            _ = services.windows.newWindow()
            let opened = { services.windows.controllers.first { !before.contains($0.state.id) && !services.windows.registry.members(of: $0.state.id).isEmpty } }
            try await PinnedPageTests.until({ opened()?.state.workspaceID != nil }, within: .seconds(60))
            let windowB = try #require(opened())
            let tab = try #require(firstTab())
            let membersA = services.windows.registry.members(of: windowA.state.id)

            windowB.sidebar.handle(.selectTab(workspace: CmuxNextSidebar.WorkspaceID(ownA), tab: CmuxNextSidebar.TabID(tab)))

            try await PinnedPageTests.until({ windowB.state.workspaceID == ownA }, within: .seconds(30), report: {
                "window B shows \(windowB.state.workspaceID ?? "nil"), window A \(windowA.state.workspaceID ?? "nil"); "
                    + "\(ownA) in \(services.windows.registry.value.owner(of: ownA) ?? "none")"
            })
            #expect(services.windows.registry.value.owner(of: ownA) == windowB.state.id, "the tab's workspace stayed in window A")
            #expect(windowA.state.workspaceID != ownA, "window A shows the workspace whose tab was clicked in window B")
            #expect(services.windows.registry.members(of: windowA.state.id) == membersA.filter { $0 != ownA })
        }
    }
}
