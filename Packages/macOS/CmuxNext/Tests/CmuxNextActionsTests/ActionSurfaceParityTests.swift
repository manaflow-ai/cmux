import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// The surface parity rule (plans/cmux-next/actions.md): every action is
/// offered on the CLI, a right-click menu and the palette, or names why not.
/// The catalog is finite, so each property below is checked for every
/// element: an exhaustive check, not a sample.
@MainActor
@Suite struct ActionSurfaceParityTests {
    let catalog = ActionCatalog.all

    @Test func everyActionDeclaresEverySurface() {
        var missing: [String] = []
        for descriptor in catalog {
            for surface in ActionSurface.allCases where descriptor.surfacePlan.decision(for: surface) == nil {
                missing.append("\(descriptor.id.rawValue): \(surface.rawValue)")
            }
        }
        #expect(missing.isEmpty, "\(missing.count) undeclared surfaces:\n\(missing.joined(separator: "\n"))")
    }

    /// Placements and exemptions never contradict each other, and every
    /// exemption fits the descriptor facts it claims.
    @Test func declarationsAreConsistent() {
        for descriptor in catalog {
            let plan = descriptor.surfacePlan
            let id = descriptor.id.rawValue
            #expect(plan.contextMenus.isEmpty || plan.contextMenuExemption == nil, "\(id): placed and exempt")
            #expect((plan.palette.exemption == .paletteInternal) == descriptor.requires.contains(.paletteOpen), "\(id): palette")
            if descriptor.isDebugOnly {
                #expect(plan.cli == .exempt(.devOnly), "\(id): a debug-only action has no CLI verb")
            }
            if plan.cli == .exempt(.devOnly) { #expect(descriptor.isDebugOnly, "\(id): devOnly but not debug-only") }
            if let mcp = plan.mcpExemption {
                #expect(plan.cli?.isOffered == true, "\(id): an MCP exemption without a CLI verb")
                #expect([.credentials, .endsApp, .systemChange].contains(mcp), "\(id): MCP reason \(mcp)")
            }
            for placement in plan.contextMenus {
                if placement.style == .choices {
                    let hasChoices = descriptor.arguments.contains {
                        ActionRegistry.menuChoices($0) != nil || ActionTargetChoices.kind(of: $0, in: descriptor) != nil
                    }
                    #expect(hasChoices, "\(id): choices needs an argument with menu choices")
                }
                if let parent = placement.parent {
                    let anchored = catalog.first { $0.id == parent }?.surfacePlan.contextMenus.contains {
                        $0.context == placement.context && $0.style == .submenu
                    }
                    #expect(anchored == true, "\(id): parent \(parent) is no submenu in \(placement.context)")
                }
            }
        }
    }

    /// A right-click on an object offers every action that acts on that
    /// kind of object (its default target, or an argument a right-click
    /// target supplies), unless the action says why not. A placement in an
    /// object-less menu (the sidebar or screen bar background) also counts:
    /// creating actions take their place from the focused object there; so
    /// does a menu on a contained object (a tab's menu reaches its pane).
    @Test func everyTargetKindMenuShowsItsActions() {
        let kindsWithMenus = Set(ActionMenuContext.allCases.compactMap(\.targetKind))
        var gaps: [String] = []
        for descriptor in catalog {
            guard let kind = descriptor.targets.first, kindsWithMenus.contains(kind) else { continue }
            let plan = descriptor.surfacePlan
            var kinds = Set(descriptor.targets)
            for argument in descriptor.arguments { if case .target(let argumentKind) = argument.kind { kinds.insert(argumentKind) } }
            let placed = plan.contextMenus.contains { placement in
                guard let menuKind = placement.context.targetKind else { return true }
                return kinds.contains(menuKind) || !kinds.isDisjoint(with: menuKind.containers)
            }
            if !placed && plan.contextMenuExemption == nil {
                gaps.append("\(descriptor.id.rawValue) (\(kind.rawValue))")
            }
        }
        #expect(gaps.isEmpty, "actions missing from their target's menu:\n\(gaps.joined(separator: "\n"))")
    }

    /// The menus are generated from the placements: each menu shows exactly
    /// the actions placed in it, nothing hand-added and nothing dropped.
    @Test func generatedMenusShowExactlyThePlacements() {
        for context in ActionMenuContext.allCases {
            let shown = Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context)))
            let placed = Set(catalog.filter { $0.surfacePlan.contextMenus.contains { $0.context == context } }.map(\.id))
            #expect(shown == placed, "\(context): shown-only \(shown.subtracting(placed)), placed-only \(placed.subtracting(shown))")
            #expect(!shown.isEmpty, "\(context) menu is empty")
        }
    }

    /// Lawrence (2026-10-01): long menus use submenus. Each menu keeps at
    /// most 12 top-level rows (a folder counts as one); the rest live in
    /// folders ("Move ▸"), and each folder holds at least two rows.
    /// Reachability inside folders is checked by the tests above, which
    /// walk submenus.
    @Test func everyMenuKeepsAShortTopLevel() {
        for context in ActionMenuContext.allCases {
            let entries = ContextMenuCatalog.shared.entries(for: context)
            let rows = entries.filter { if case .separator = $0 { false } else { true } }
            #expect(rows.count <= 12, "\(context) has \(rows.count) top-level rows")
            for case .folder(let folder, let children) in entries {
                let count = ContextMenuCatalog.shared.referencedIDs(children).count
                #expect(count >= 2, "\(context) folder \(folder) has \(count) rows")
            }
        }
    }

    @Test func cliNamesAndShortcutsAreUnique() {
        var byName: [String: ActionID] = [:]
        for descriptor in catalog where descriptor.surfacePlan.cli?.isOffered == true {
            if let other = byName[descriptor.cliName] {
                Issue.record("cliName \(descriptor.cliName): \(other) and \(descriptor.id)")
            }
            byName[descriptor.cliName] = descriptor.id
        }
        #expect(ActionRegistry.standard().shortcutConflicts().isEmpty)
    }

    /// Every right-click item runs the action it shows through
    /// `ActionRegistry.perform` with the item's target and the user origin:
    /// the same path the palette, the keyboard and the CLI use.
    @Test func everyMenuItemRunsItsOwnActionThroughTheRegistry() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var runs: [(ActionID, ActionInvocation)] = []
        for descriptor in catalog {
            let id = descriptor.id
            registry.bind(id, invoke: { runs.append((id, $0)) })
        }
        registry.argumentCollector = { runs.append(($0, $1)) }
        registry.confirmationPresenter = { id, invocation, _ in runs.append((id, invocation)) }
        var checked = 0
        for context in ActionMenuContext.allCases {
            let target = context.targetKind.map { ActionTargetRef(kind: $0, id: "t1") }
            let menu = registry.makeContextMenu(for: context, target: target)
            for item in Self.leafItems(menu) {
                guard let payload = item.representedObject as? ActionMenuPayload else {
                    Issue.record("\(context): \(item.title) has no action payload")
                    continue
                }
                runs.removeAll()
                _ = (item.target as? NSObject)?.perform(item.action, with: item)
                let run = try #require(runs.first, "\(context): \(payload.id) did not run")
                #expect(run.0 == payload.id, "\(context): item \(payload.id) ran \(run.0)")
                #expect(run.1.target == target, "\(context): \(payload.id) target")
                #expect(run.1.origin == .user, "\(context): \(payload.id) origin")
                checked += 1
            }
        }
        #expect(checked > 300)
    }

    /// The checked-in export (`plans/cmux-next/action-surfaces.json`) that
    /// the Rust CLI and MCP parity tests, cmux-browser and GPUI read matches
    /// the catalog: surfaces, title and its localization key, default
    /// shortcut and chord. A changed title or shortcut fails here.
    /// `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter ActionSurfaceParityTests` rewrites it.
    @Test func exportIsFresh() throws {
        let url = Self.planURL("action-surfaces.json")
        let current = ActionSurfaceExport.json(catalog, titles: try Self.titleCatalog())
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try current.write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "action-surfaces.json is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
    }

    /// The generated block of plans/cmux-next/actions.md (counts, every
    /// menu in order, every exemption) matches the catalog, so menu order
    /// changes and new exemptions are reviewed as text.
    @Test func reportIsFresh() throws {
        let url = Self.planURL("actions.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let current = ActionSurfaceReport(catalog, menus: .shared).markdown
        let start = try #require(text.range(of: ActionSurfaceReport.begin), "actions.md has no generated block")
        let end = try #require(text.range(of: ActionSurfaceReport.end), "actions.md has no generated block end")
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try (String(text[..<start.lowerBound]) + current + String(text[end.upperBound...])).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        #expect(String(text[start.lowerBound..<end.upperBound]) == current, "actions.md is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
    }

    /// Every id in the surface tables names a catalog action, and no id is
    /// listed under two reasons (a typo would otherwise be ignored).
    @Test func surfaceTablesNameOnlyCatalogActions() {
        let ids = Set(catalog.map(\.id))
        var tableIDs = Array(ActionSurfaceCatalog.placements.keys) + Array(ActionSurfaceCatalog.cliNamed)
        for table in [ActionSurfaceCatalog.paletteExemptionsByReason, ActionSurfaceCatalog.cliExemptionsByReason, ActionSurfaceCatalog.contextMenuExemptionsByReason,
                      ActionSurfaceCatalog.mcpExemptionsByReason] {
            let listed = table.values.flatMap { $0 }
            #expect(Set(listed).count == listed.count, "an id listed under two reasons")
            tableIDs += listed
        }
        let unknown = Set(tableIDs).subtracting(ids)
        #expect(unknown.isEmpty, "unknown ids: \(unknown.map(\.rawValue).sorted())")
        #expect(ActionSurfaceCatalog.cliNamed.isDisjoint(with: ActionSurfaceCatalog.cliExemption.keys), "named and exempt")
    }

    /// Every string catalog of CmuxNextActions, from the source tree.
    static func titleCatalog() throws -> ActionTitleCatalog {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextActions")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try ActionTitleCatalog(catalogs: files.map { ($0.deletingPathExtension().lastPathComponent, try Data(contentsOf: $0)) })
    }

    /// Nearly every title names its key, and a named key's English text is
    /// the title the app shows.
    @Test func exportNamesTitleKeys() throws {
        let titles = try Self.titleCatalog()
        var named = 0
        for descriptor in catalog {
            guard let entry = titles.entry(for: descriptor) else { continue }
            named += 1
            #expect(entry.english == descriptor.title, "\(descriptor.id)")
        }
        #expect(named * 10 >= catalog.count * 9, "only \(named) of \(catalog.count) titles name a key")
        for category in ActionCategory.allCases {
            let entry = titles.entry(key: category.titleKey, table: category.titleTable)
            #expect(entry?.english == category.title, "palette section \(category.rawValue) names no string")
        }
    }

    static func planURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plans/cmux-next/\(name)")
    }

    static func leafItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if item.isSeparatorItem { return [] }
            if let submenu = item.submenu, item.representedObject == nil { return leafItems(submenu) }
            return [item]
        }
    }
}
