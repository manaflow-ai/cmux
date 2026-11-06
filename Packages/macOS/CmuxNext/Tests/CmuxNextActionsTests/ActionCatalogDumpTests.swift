import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// Every field of every catalog descriptor, in catalog order, as the app resolves it at launch,
/// checked in at `plans/cmux-next/action-catalog.json`. The Rust action catalog
/// (`cmux-tui/crates/cmux-action-catalog`) is compared with it field by field
/// (`tests/swift_parity.rs`), so the move of the catalog data out of Swift is proven
/// byte-for-byte before the Swift literals are deleted.
///
/// The dump reflects each value (`Mirror`), so a stored field added to a descriptor, an
/// argument or a placement is dumped without a change here. Strings are the English the
/// app resolves; the Rust side finds their keys in the string catalogs.
@MainActor
@Suite struct ActionCatalogDumpTests {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/cmux-next/action-catalog.json")

    /// A placeholder file (`{}`) asks for a fresh dump: a fleet suite run writes it.
    static var wantsDump: Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
    }

    @Test(.enabled(if: wantsDump || ["CMUX_CHECK_GENERATED_EXPORTS", "CMUX_UPDATE_ACTION_SURFACES"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
    func dumpIsFresh() throws {
        let url = Self.url
        let current = try Self.json()
        if Self.wantsDump || ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try current.write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "action-catalog.json is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
    }

    /// The dump never falls back to a value's description: every leaf is a known kind.
    @Test func dumpHasNoOpaqueValues() throws {
        let text = try Self.json()
        #expect(!text.contains("\"<opaque"), "a value the dump cannot reflect")
    }

    static func json() throws -> String {
        var groupOf: [String: String] = [:]
        for group in ActionCatalog.groups {
            for descriptor in group.descriptors() where groupOf[descriptor.id.rawValue] == nil {
                groupOf[descriptor.id.rawValue] = String(describing: group)
            }
        }
        let actions: [Any] = ActionCatalog.all.map { descriptor in
            var row = encode(descriptor) as? [String: Any] ?? [:]
            row["group"] = groupOf[descriptor.id.rawValue] ?? NSNull()
            row["computed"] = [
                "cli": descriptor.cli,
                "is_palette_visible": descriptor.isPaletteVisible,
                "palette_suggestion_rank": descriptor.paletteSuggestionRank.map { $0 as Any } ?? NSNull(),
                "palette_tier": String(describing: descriptor.paletteTier),
                "palette_family": descriptor.paletteFamily.map { $0.id as Any } ?? NSNull(),
                "canonical_action_id": descriptor.canonicalActionID.rawValue,
                "default_aliases": ActionSurfaceExport.defaultAliases(for: descriptor.id),
            ] as [String: Any]
            return row
        }
        let categories: [Any] = ActionCategory.allCases.map { category in
            [
                "id": category.rawValue, "title": category.title, "title_key": category.titleKey,
                "title_table": category.titleTable, "palette_section_id": category.paletteSectionID,
                "palette_section_order": category.paletteSectionOrder, "sort_order": category.sortOrder,
            ] as [String: Any]
        }
        let folders: [Any] = MenuFolder.allCases.map { folder in
            ["id": folder.rawValue, "title": folder.title, "symbol": folder.symbol, "group": String(describing: folder.group)] as [String: Any]
        }
        let bindings: [String: Any] = [
            "tab_cycle_aliases": KeyBindingDefaults.tabCycleAliases.map(encodeBinding),
            "workspaces_as_tabs": KeyBindingDefaults.workspacesAsTabs.map(encodeBinding),
            "home_chat_switching": KeyBindingDefaults.homeChatSwitching.map(encodeBinding),
            "scoped_defaults": KeyBindingDefaults.scopedDefaults.map(encodeBinding),
            "pane_resize_aliases": KeyBindingDefaults.paneResizeAliases.map(encodeBinding),
            "pane_focus_aliases": KeyBindingDefaults.paneFocusAliases.map(encodeBinding),
            "focus_history_aliases": KeyBindingDefaults.focusHistoryAliases.map(encodeBinding),
            "zoom_aliases": KeyBindingDefaults.zoomAliases.map(encodeBinding),
            "space_aliases": KeyBindingDefaults.spaceAliases.map(encodeBinding),
            "palette_keys": KeyBindingDefaults.paletteKeys.map(encodeBinding),
            "list_navigation": KeyBindingDefaults.listNavigation.map(encodeBinding),
            "home_chat_scoped": KeyBindingDefaults.homeChatScoped.map(\.rawValue).sorted(),
            "home_scoped": KeyBindingDefaults.homeScoped.map(\.rawValue).sorted(),
            "yields_to_code_editor": KeyBindingDefaults.yieldsToCodeEditor.map(\.rawValue).sorted(),
            "yields_to_terminal": KeyBindingDefaults.yieldsToTerminal.map(\.rawValue).sorted(),
            "yields_to_web_content": KeyBindingDefaults.yieldsToWebContent.map(\.rawValue).sorted(),
            "text_input_keys": KeyBindingDefaults.textInputKeys.map { ActionSurfaceExport.wireShortcut($0) }
                .sorted { "\($0)" < "\($1)" },
        ]
        let palette: [String: Any] = [
            "daily": ActionDescriptor.paletteDailyActions.map(\.rawValue).sorted(),
            "niche": ActionDescriptor.paletteNicheActions.map(\.rawValue).sorted(),
            "suggestions": ActionDescriptor.paletteSuggestions.map(\.rawValue),
            "aliases": encode(ActionDescriptor.paletteAliases),
            "families": ActionDescriptor.paletteFamilies.map { encode($0) },
            "duplicates": encode(ActionDescriptor.paletteDuplicates),
        ]
        let root: [String: Any] = [
            "version": 1,
            "actions": actions,
            "legacy_aliases": encode(ActionCatalog.legacyAliases),
            "categories": categories,
            "menu_folders": folders,
            "key_binding_defaults": bindings,
            "palette": palette,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    static func encodeBinding(_ binding: KeyBinding) -> Any {
        var row = encode(binding) as? [String: Any] ?? [:]
        row["when_text"] = binding.when.map { $0.text as Any } ?? NSNull()
        return row
    }

    /// A value as JSON: structs by stored field, enums as their raw value or `{case: payload}`,
    /// option sets by member name, shortcuts in the export's wire form.
    static func encode(_ value: Any) -> Any {
        switch value {
        case let value as String: return value
        case let value as Bool: return value
        case let value as Int: return value
        case let value as UInt8: return Int(value)
        case let value as UInt32: return Int(value)
        case let value as Double: return value
        case let value as ActionID: return value.rawValue
        case let value as Shortcut: return ActionSurfaceExport.wireShortcut(value)
        case let value as ActionContext: return ContextMenuCatalog.contextNames(value)
        case let value as ActionSurfaces:
            let names: [(ActionSurfaces, String)] = [(.palette, "palette"), (.keyboard, "keyboard"), (.menu, "menu"), (.contextMenu, "contextMenu")]
            return names.compactMap { value.contains($0.0) ? $0.1 : nil }
        case let value as ClosedRange<Int>: return ["min": value.lowerBound, "max": value.upperBound]
        case let value as Duration: return "\(value)"
        case let value as any RawRepresentable where value.rawValue is String:
            return value.rawValue
        default: break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let child = mirror.children.first else { return NSNull() }
            return encode(child.value)
        case .collection:
            return mirror.children.map { encode($0.value) }
        case .set:
            return mirror.children.map { encode($0.value) }.sorted { "\($0)" < "\($1)" }
        case .dictionary:
            var out: [String: Any] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2 else { continue }
                let key = encode(pair[0].value)
                out[key as? String ?? "\(key)"] = encode(pair[1].value)
            }
            return out
        case .enum:
            guard let child = mirror.children.first, let label = child.label else { return String(describing: value) }
            return [label: encode(child.value)]
        case .tuple:
            let children = Array(mirror.children)
            if children.allSatisfy({ $0.label?.hasPrefix(".") ?? true }) { return children.map { encode($0.value) } }
            var out: [String: Any] = [:]
            for (index, child) in children.enumerated() {
                let label = child.label.map { $0.hasPrefix(".") ? String(index) : $0 } ?? String(index)
                out[label] = encode(child.value)
            }
            return out
        case .struct, .class:
            var out: [String: Any] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                out[label] = encode(child.value)
            }
            return out
        default:
            return "<opaque \(type(of: value))>"
        }
    }
}
