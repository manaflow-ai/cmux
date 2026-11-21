import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import Foundation
import Testing

/// New ▸ {Terminal, Browser, Agent Chat, New Tab Page} ▸ Fork To's ten places: one table makes
/// the 4 × 10 actions, each place asks for its own layout op, and the menus show them as Fork To
/// shows its destinations.
@MainActor
struct NewAtPlacementTests {
    static let kinds = ["terminal", "browser", "agentChat", "newTabPage"]

    /// The places are Fork To's destinations, in its order.
    @Test func thePlacesAreForkTosDestinations() {
        let places = ActionID.newPlacementActions.prefix(10).compactMap(\.newPlacement?.place)
        #expect(places == ForkConversationTests.destinations.map(\.1.rawValue))
        #expect(ActionID.newPlacementActions.count == 40)
        #expect(ActionID.newPlacementActions.compactMap(\.newPlacement).map(\.kind) == Self.kinds.flatMap { Array(repeating: $0, count: 10) })
    }

    /// Every row is a palette row with its own title and a `cmux pane new-…` verb.
    @Test func everyActionIsAPaletteRowAndACLIVerb() throws {
        var titles = Set<String>(), verbs = Set<String>()
        for id in ActionID.newPlacementActions {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.cliName.hasPrefix("pane new-"), "\(id)")
            #expect(descriptor.surfacePlan.cli == .offered, "\(id)")
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(descriptor.title.hasPrefix("New "), "\(id)")
            titles.insert(descriptor.title)
            verbs.insert(descriptor.cliName)
        }
        #expect(titles.count == 40 && verbs.count == 40)
        let left = try #require(ActionCatalog.all.first { $0.id == "new.browser.left" })
        #expect(left.title == "New Browser to the Left")
        #expect(left.cliName == "pane new-browser-to-left")
    }

    /// Each kind and place is bound; a new row says why it is off, as New Row does.
    @Test func everyActionIsBoundAndARowNeedsRows() {
        let services = ForkConversationTests.services()
        AppActions.bind(services)
        let ctx = AppActionContext(services: services)
        for id in ActionID.newPlacementActions + ActionID.newPlacementSubmenus {
            #expect(services.registry.isBound(id), "\(id)")
            guard let (kind, place) = id.newPlacement else { continue }
            let expected = place == "row" ? ColumnHandlers.newRowUnavailableReason(ctx)
                : kind == "terminal" && place == "columnLeft" ? ColumnHandlers.newColumnLeftUnavailableReason(ctx) : nil
            #expect(services.registry.unavailableReason(for: id) == expected, "\(id)")
        }
    }

    /// One test per place: whatever the kind, the place asks for its layout op (the reducer's plan,
    /// or the same op made and moved on an app FFI from before the plan), and a new tab is made in the pane.
    @Test(arguments: [
        ("right", NewPlacementPlan.Op.split(edge: "right")), ("left", .split(edge: "left")),
        ("up", .split(edge: "top")), ("down", .split(edge: "bottom")),
        ("columnRight", .column(left: false)), ("columnLeft", .column(left: true)), ("row", .row),
        ("tab", .tab), ("workspace", .workspace), ("window", .window),
    ])
    func eachPlaceAsksForItsOp(place: String, op: NewPlacementPlan.Op) throws {
        for kind in Self.kinds {
            let plan = try #require(NewPlacementPlan(kind: kind, place: place, tabSplit: true) ?? NewPlacementPlan.fallback(place: place))
            #expect(plan.op == op, "\(kind) at \(place)")
            if place == "tab" { #expect(plan.madeInPlace, "\(kind) in a new tab") }
            if place == "workspace" || place == "window" { #expect(!plan.madeInPlace, "\(kind) at \(place)") }
        }
        #expect(NewPlacementPlan.fallback(place: place)?.op == op)
    }

    /// Without the reducer's answer every place is made then moved, but a tab, made in the pane.
    @Test func theFallbackMakesThenMoves() {
        for place in ForkConversationTests.destinations.map(\.1.rawValue) {
            #expect(NewPlacementPlan.fallback(place: place)?.madeInPlace == (place == "tab"), "\(place)")
        }
        #expect(NewPlacementPlan.fallback(place: "nowhere") == nil)
    }

    /// A browser the CLI, MCP or a script opens at any place is made here and marked agent-driven before its
    /// first load (no saved password fills in it); only a new tab uses openBrowser, which marks it itself.
    @Test func anAutomatedBrowserIsMarkedAgentDrivenAtEveryPlace() throws {
        for place in ForkConversationTests.destinations.map(\.1.rawValue) {
            let plan = try #require(NewPlacementPlan(kind: "browser", place: place, tabSplit: true) ?? NewPlacementPlan.fallback(place: place))
            for origin in [ActionOrigin.cli, .mcp, .script] {
                let route = NewAtPlacement.route("browser", plan, origin: origin)
                #expect(route.agentDriven, "\(place) from \(origin)")
                #expect(route.ownCreate == (place == "tab"), "\(place) from \(origin)")
            }
            // A person's browser keeps the fast path and is not marked.
            let person = NewAtPlacement.route("browser", plan, origin: .user)
            #expect(!person.agentDriven && person.ownCreate == plan.madeInPlace, "\(place)")
            // Only browsers are marked.
            #expect(!NewAtPlacement.route("terminal", plan, origin: .cli).agentDriven)
        }
    }

    /// Cmd-D's split on a terminal opens toward the place's edge.
    @Test func aSplitEdgeIsItsPaneDirection() {
        #expect(NewAtPlacement.direction("right") == .right)
        #expect(NewAtPlacement.direction("left") == .left)
        #expect(NewAtPlacement.direction("top") == .up)
        #expect(NewAtPlacement.direction("bottom") == .down)
    }

    /// The pane menu's New ▸ holds a submenu per kind, beside New Column and Split Browser, each
    /// with the ten places in Fork To's three sections (splits; columns and row; tab, workspace, window).
    @Test func thePaneMenusNewFolderHasEachKindWithForkTosSections() throws {
        let services = ForkConversationTests.services()
        AppActions.bind(services)
        let menu = services.registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p"))
        for kind in Self.kinds {
            let submenu = try #require(Self.submenu(of: kind, in: menu), "\(kind)")
            #expect(Self.sections(submenu) == [4, 3, 3], "\(kind)")
            let ids = submenu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
            #expect(ids == ActionID.newPlacementActions.filter { $0.newPlacement?.kind == kind }, "\(kind)")
        }
        // The New folder keeps its other rows.
        let all = Self.allIDs(menu)
        #expect(["newColumn", "newColumnLeft", "splitBrowserRight", "splitBrowserDown"].allSatisfy { all.contains(ActionID(rawValue: $0)) })
    }

    /// The pane's ••• shows the same New folder (``ContextMenuCatalog/newPlacementFolder()``).
    @Test func theMoreMenuGetsTheSameNewFolder() throws {
        let folder = try #require(ContextMenuCatalog.shared.newPlacementFolder())
        guard case .folder(.new, let children) = folder else { Issue.record("not the New folder"); return }
        #expect(children.compactMap { if case .submenu(let id, _) = $0 { id } else { nil } } == ActionID.newPlacementSubmenus)
        let services = ForkConversationTests.services()
        AppActions.bind(services)
        let menu = services.registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p"), entries: [folder], customize: false)
        for kind in Self.kinds {
            let submenu = try #require(Self.submenu(of: kind, in: menu), "\(kind)")
            #expect(Self.sections(submenu) == [4, 3, 3], "\(kind)")
        }
    }

    /// The submenu whose rows open `kind`.
    static func submenu(of kind: String, in menu: NSMenu) -> NSMenu? {
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            let ids = submenu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
            if !ids.isEmpty, ids.allSatisfy({ $0.newPlacement?.kind == kind }) { return submenu }
            if let found = Self.submenu(of: kind, in: submenu) { return found }
        }
        return nil
    }

    /// The row counts between separators.
    static func sections(_ menu: NSMenu) -> [Int] {
        menu.items.split(whereSeparator: \.isSeparatorItem).map(\.count)
    }

    static func allIDs(_ menu: NSMenu) -> [ActionID] {
        menu.items.flatMap { item in (ActionRegistry.menuRun(of: item).map { [$0.id] } ?? []) + (item.submenu.map(allIDs) ?? []) }
    }
}
