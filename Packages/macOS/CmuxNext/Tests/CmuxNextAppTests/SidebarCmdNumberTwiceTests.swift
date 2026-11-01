import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-19: "If I press Command-1 twice, the first time Home is highlighted but the
/// second time nothing is highlighted." Cmd-`n` on the item it already selected keeps that item
/// selected and drawn selected (its band or block item active, or its list row selected); it never
/// clears the selection. Runs the app's action registry (the key binding's action) against a
/// same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarCmdNumberTwiceTests {
    /// What the sidebar draws selected: the active top item (band or block), else the selected row.
    static func drawnSelection(_ view: SidebarView) -> String {
        if let item = view.list.activeTopItem ?? view.aboveRegion.activeItem { return "item:\(item.rawValue)" }
        return view.list.selectedRowKey.map { "row:\($0)" } ?? "nothing"
    }

    static func expectedDrawn(_ item: SidebarItem?, _ view: SidebarView) -> String {
        switch item {
        case let .topItem(id)?: "item:\(id.rawValue)"
        case let .workspace(id)?: view.list.displayed.row(for: .workspace(id)) == nil ? "nothing" : "row:\(SidebarRowKey.workspace(id))"
        case let .group(id)?: "row:\(SidebarRowKey.group(id))"
        case nil: "nothing"
        }
    }

    /// The sidebar's top items (Home, the App Store) have settled into its item order, so a pick reads
    /// the order the presses read. Until then Cmd-2 can mean the window's workspace (with one
    /// workspace and Cmd-9 = last, an order without the App Store makes the workspace item 2) and the
    /// App Store a moment later. Settled: when the daemon serves the sidebar document, it is loaded
    /// and the rows draw its latest version (its bands replace the layout, and a block's items are
    /// stops where the block draws); the model shows the layout service's document; the item
    /// presentation (`itemInfo`) covers every top item; and every top item that draws (not hidden,
    /// missing or a suppressed app's) is a stop. Not the apps list: these tests never start the apps
    /// client (only the AppDelegate does), so it never lands, and without it a first-party app item
    /// draws as its former built-in, neither missing nor suppressed.
    static func topItemsSettled(_ window: WindowController, _ services: AppServices) -> Bool {
        if services.machines.local.supports(DaemonCapabilities.sidebarDoc) {
            guard let doc = SidebarDocStore.current, doc.isActive, doc.shown != nil, doc.shownVersion == doc.version else { return false }
        }
        let model = window.sidebar.model
        guard model.layout == SidebarRows.visibleLayout(services.sidebarLayout.document) else { return false }
        let top = model.layout.sections(in: .top, room: model.activeProfileID?.rawValue).flatMap(\.items)
        guard !top.isEmpty, top.allSatisfy({ model.itemInfo[$0.id] != nil }) else { return false }
        let stops = Set(model.itemOrder.items)
        return top.allSatisfy { item in
            let info = model.itemInfo[item.id]
            let draws = info?.isHidden != true && info?.isMissing != true && !model.suppressedApps.contains(item.owningAppID ?? "")
            return !draws || stops.contains(.topItem(item.id))
        }
    }

    /// What a failed wait or expectation needs: the item order at pick time and now, the model's
    /// selection and what it draws, the window's selection (its state, the truth) and page.
    static func report(_ window: WindowController, _ services: AppServices, picked: SidebarItem?, orderAtPick: [SidebarItem]?) -> String {
        let model = window.sidebar.model, view = window.sidebar.container.sidebarView
        let top = model.layout.sections(in: .top, room: model.activeProfileID?.rawValue).flatMap(\.items).map(\.id.rawValue)
        let doc = SidebarDocStore.current.map { "active \($0.isActive), version \($0.version), shown \($0.shownVersion)" } ?? "none"
        let pick = picked.map { String(describing: $0) } ?? "nil", atPick = orderAtPick.map { String(describing: $0) } ?? "not picked"
        let selection = "model selection \(String(describing: model.selectedItem)), drawn \(drawnSelection(view)), "
            + "window selection \(String(describing: SidebarNavigation.current(in: window, services))), "
            + "page \(String(describing: window.state.page)), workspace \(window.state.workspaceID ?? "nil")"
        return "picked \(pick); order at pick \(atPick); order now \(model.itemOrder.items); \(selection); top items \(top), "
            + "item info \(model.itemInfo.keys.map(\.rawValue).sorted()), suppressed apps \(model.suppressedApps.sorted()); sidebar document \(doc)"
    }

    @Test(arguments: [1, 2])
    func pressingCmdNumberTwiceKeepsItsItemSelectedAndDrawn(_ number: Int) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let view = window.sidebar.container.sidebarView
            let model = window.sidebar.model
            // Home (Cmd-1) is the home workspace, which the home service asks the store for on each
            // connect; the app starts that service at launch, this harness does not. Without it
            // `home.show` refuses and Cmd-1 selects nothing.
            services.home.ensureHomeWorkspace(connection)
            try await PinnedPageTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                            report: { "no home workspace: \(services.home.homeWorkspaceStep)" })
            // What a parallel run does: another suite binds its own AppServices meanwhile (SidebarMenuLookTests.menu,
            // and every AppActions.bind), whose first sidebarLayout read sets the process-wide SidebarDocStore.current.
            let other = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(other)
            try await PinnedPageTests.until({ Self.topItemsSettled(window, services) }, within: .seconds(30), report: {
                "the sidebar's top items never settled: " + Self.report(window, services, picked: nil, orderAtPick: nil)
            })
            let orderAtPick = model.itemOrder.items
            let picked = try #require(model.itemOrder.pick(number, SidebarNavigation.settings(services)), "Cmd-\(number) picks nothing")
            let report = { Self.report(window, services, picked: picked, orderAtPick: orderAtPick) }
            // After each press: the window selects the picked item and the sidebar draws it (its
            // observation hop and the selection hold's limit), waited on, not slept for.
            let selectsPicked = {
                model.itemOrder.stop(for: SidebarNavigation.current(in: window, services)) == picked
                    && model.selectedItem == picked && Self.drawnSelection(view) == Self.expectedDrawn(picked, view)
            }

            #expect(services.registry.perform("selectWorkspaceByNumber", argument: "\(number)"))
            try await PinnedPageTests.until(selectsPicked, within: .seconds(10), report: { "the first Cmd-\(number) did not select its item: " + report() })
            let first = (model.selectedItem, Self.drawnSelection(view))
            #expect(first.1 != "nothing", "the first Cmd-\(number) drew nothing selected: \(report())")

            #expect(services.registry.perform("selectWorkspaceByNumber", argument: "\(number)"))
            // Pressed again on its own item, Cmd-`n` runs nothing: the window state (the truth) is unchanged at once.
            #expect(model.itemOrder.stop(for: SidebarNavigation.current(in: window, services)) == picked,
                    "the second Cmd-\(number) changed the window's selection: \(report())")
            // The wait below holds already, so it returns in this turn: draw the model now (as a hop
            // later would), so what the sidebar draws after the press is what is read.
            view.renderNow()
            try await PinnedPageTests.until(selectsPicked, within: .seconds(10), report: { "the second Cmd-\(number) lost its item: " + report() })
            let second = (model.selectedItem, Self.drawnSelection(view))
            #expect(second.0 == first.0, "the second Cmd-\(number) changed the selection from \(String(describing: first.0)) to \(String(describing: second.0)): \(report())")
            #expect(second.1 == first.1, "the second Cmd-\(number) drew \(second.1), the first \(first.1): \(report())")
            #expect(second.1 == Self.expectedDrawn(second.0, view) && second.1 != "nothing", "after the second Cmd-\(number) the sidebar draws \(second.1): \(report())")
        }
    }
}
