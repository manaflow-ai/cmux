import Foundation

/// `plans/cmux-next/action-catalog.json`: the decoded Rust catalog dumped field for field, the way the
/// Swift catalog was dumped before its literals were deleted (Rust's `tests/swift_parity.rs` compares
/// its own JSON with the same file). `ActionCatalogDumpTests` checks it on the Mac and the action
/// exporter (`cmux-next-action-exports`) writes it on Linux, through this one encoder.
///
/// The dump reflects each value (`Mirror`), so a stored field added to a descriptor, an argument or a
/// placement is dumped without a change here. Strings are English.
nonisolated enum ActionCatalogDump {
    static func json(_ catalog: RustActionCatalog) throws -> String {
        let actions: [Any] = catalog.descriptors.map { descriptor in
            var row = encode(descriptor) as? [String: Any] ?? [:]
            row["group"] = catalog.groupOf[descriptor.id] ?? NSNull()
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
                "id": category.rawValue, "title": catalog.categories[category]?.title ?? "", "title_key": category.titleKey,
                "title_table": category.titleTable, "palette_section_id": category.paletteSectionID,
                "palette_section_order": category.paletteSectionOrder, "sort_order": category.sortOrder,
            ] as [String: Any]
        }
        let folders: [Any] = MenuFolder.allCases.map { folder in
            ["id": folder.rawValue, "title": catalog.folders[folder]?.title ?? "", "symbol": folder.symbol, "group": String(describing: folder.group)] as [String: Any]
        }
        let list = { (name: String) in (catalog.bindings[name] ?? []).map(encodeBinding) }
        let ids = { (name: String) in (catalog.idLists[name] ?? []).map(\.rawValue).sorted() }
        let bindings: [String: Any] = [
            "tab_cycle_aliases": list("tab_cycle_aliases"),
            "workspaces_as_tabs": list("workspaces_as_tabs"),
            "home_chat_switching": list("home_chat_switching"),
            "scoped_defaults": list("scoped_defaults"),
            "pane_resize_aliases": list("pane_resize_aliases"),
            "pane_focus_aliases": list("pane_focus_aliases"),
            "focus_history_aliases": list("focus_history_aliases"),
            "zoom_aliases": list("zoom_aliases"),
            "space_aliases": list("space_aliases"),
            "palette_keys": list("palette_keys"),
            "list_navigation": list("list_navigation"),
            "home_chat_scoped": ids("home_chat_scoped"),
            "home_scoped": ids("home_scoped"),
            "yields_to_code_editor": ids("yields_to_code_editor"),
            "yields_to_terminal": ids("yields_to_terminal"),
            "yields_to_web_content": ids("yields_to_web_content"),
            "text_input_keys": catalog.textInputKeys.map { ActionSurfaceExport.wireShortcut($0) }
                .sorted { sortKey($0) < sortKey($1) },
        ]
        let palette: [String: Any] = [
            "daily": catalog.paletteDaily.map(\.rawValue).sorted(),
            "niche": catalog.paletteNiche.map(\.rawValue).sorted(),
            "suggestions": catalog.paletteSuggestions.map(\.rawValue),
            "aliases": encode(catalog.paletteAliases),
            "families": catalog.paletteFamilies.map { encode($0) },
            "duplicates": encode(catalog.paletteDuplicates),
        ]
        let root: [String: Any] = [
            "version": 1,
            "actions": actions,
            "legacy_aliases": encode(catalog.legacyAliases),
            "categories": categories,
            "menu_folders": folders,
            "key_binding_defaults": bindings,
            "palette": palette,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    /// A wire shortcut's order in a set: its key, then its modifiers as JSON text (`["cmd"]`
    /// before `[]`), the order the Rust catalog's own dump uses.
    static func sortKey(_ wire: [String: Any]) -> String {
        let modifiers = (wire["modifiers"] as? [String] ?? []).map { "\"\($0)\"" }.joined(separator: ",")
        return "\(wire["key"] as? String ?? "")\u{0}[\(modifiers)]"
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
