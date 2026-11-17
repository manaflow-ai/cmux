public import AppKit
import CCmuxActionCatalogFFI
import Foundation
import os

/// cmux NEXT's action catalog, read once from Rust (cmux-tui/crates/cmux-action-catalog, linked
/// through CCmuxAppFFI), in the app's language. Every descriptor field, every title and its
/// translations, the default key bindings beyond an action's own shortcut, the palette tables,
/// the category and menu folder titles: Rust holds them, Swift binds the handlers.
///
/// The JSON is built once per language in Rust and decoded here once, on first use
/// (`ActionCatalog.all`); the decode never touches disk.
nonisolated struct RustActionCatalog: Sendable {
    let descriptors: [ActionDescriptor]
    /// Each action's catalog group (`AppStoreActionCatalog`, ...), by id.
    let groupOf: [ActionID: String]
    let legacyAliases: [ActionID: ActionID]
    let bindings: [String: [KeyBinding]]
    let idLists: [String: [ActionID]]
    let textInputKeys: Set<Shortcut>
    let paletteDaily: Set<ActionID>
    let paletteNiche: Set<ActionID>
    let paletteSuggestions: [ActionID]
    let paletteAliases: [ActionID: [String]]
    let paletteFamilies: [PaletteFamily]
    let paletteDuplicates: [ActionID: ActionID]
    let categories: [ActionCategory: (title: String, titleKey: String, titleTable: String)]
    let folders: [MenuFolder: (title: String, symbol: String, group: MenuGroup)]

    /// In the language the app's own strings resolve to: the bundle negotiates the person's whole
    /// preference list against the localizations it ships (Swedish, Japanese, English gives
    /// Japanese), as `String(localized:bundle:)` does.
    static let shared: RustActionCatalog = load(language: Bundle.module.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en")

    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "action-catalog")

    /// The catalog JSON for `language` from the Rust library.
    static func json(language: String) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        let status = Array(language.utf8).withUnsafeBufferPointer { tag in
            cmux_action_catalog_json(tag.baseAddress, tag.count, &pointer, &length)
        }
        guard status == 0, let pointer else { return nil }
        // The library keeps these bytes for the life of the process.
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: length, deallocator: .none)
    }

    static func load(language: String) -> RustActionCatalog {
        guard let data = json(language: language),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            log.fault("the Rust action catalog did not load")
            return RustActionCatalog(root: [:])
        }
        return RustActionCatalog(root: root)
    }

    init(root: [String: Any]) {
        var actions = root["actions"] as? [[String: Any]] ?? []
        #if !DEBUG
        actions = Self.withoutDebugBuildEntries(actions, root["debug_build_only"] as? [String: Any] ?? [:])
        #endif
        descriptors = actions.compactMap(Self.descriptor)
        var groupOf: [ActionID: String] = [:]
        for row in actions {
            if let id = row["id"] as? String, let group = row["group"] as? String { groupOf[ActionID(rawValue: id)] = group }
        }
        self.groupOf = groupOf
        legacyAliases = Self.idMap(root["legacy_aliases"])
        let defaults = root["key_binding_defaults"] as? [String: Any] ?? [:]
        var bindings: [String: [KeyBinding]] = [:]
        var idLists: [String: [ActionID]] = [:]
        for (name, value) in defaults {
            guard let list = value as? [Any] else { continue }
            if let rows = list as? [[String: Any]], rows.first?["command"] != nil {
                bindings[name] = rows.compactMap(Self.binding)
            } else if let ids = list as? [String] {
                idLists[name] = ids.map(ActionID.init(rawValue:))
            }
        }
        self.bindings = bindings
        self.idLists = idLists
        textInputKeys = Set((defaults["text_input_keys"] as? [[String: Any]] ?? []).compactMap(Self.shortcut))
        let palette = root["palette"] as? [String: Any] ?? [:]
        paletteDaily = Set(Self.ids(palette["daily"]))
        paletteNiche = Set(Self.ids(palette["niche"]))
        paletteSuggestions = Self.ids(palette["suggestions"])
        var aliases: [ActionID: [String]] = [:]
        for (id, words) in palette["aliases"] as? [String: [String]] ?? [:] { aliases[ActionID(rawValue: id)] = words }
        paletteAliases = aliases
        paletteFamilies = (palette["families"] as? [[String: Any]] ?? []).map { family in
            let members = Self.ids(family["members"])
            let id = family["id"] as? String ?? ""
            if let parent = family["parent"] as? String {
                return PaletteFamily(id, parent: ActionID(rawValue: parent), members: members)
            }
            return PaletteFamily(id, title: family["title"] as? String ?? "", symbol: family["symbol"] as? String ?? "", members: members)
        }
        paletteDuplicates = Self.idMap(palette["duplicates"])
        var categories: [ActionCategory: (title: String, titleKey: String, titleTable: String)] = [:]
        for row in root["categories"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String, let category = ActionCategory(rawValue: id) else { continue }
            categories[category] = (row["title"] as? String ?? id, row["title_key"] as? String ?? "category.\(id)",
                                    row["title_table"] as? String ?? "Localizable")
        }
        self.categories = categories
        var folders: [MenuFolder: (title: String, symbol: String, group: MenuGroup)] = [:]
        for row in root["menu_folders"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String, let folder = MenuFolder(rawValue: id),
                  let group = (row["group"] as? String).flatMap({ Self.groupsByName[$0] })
            else { continue }
            folders[folder] = (row["title"] as? String ?? id, row["symbol"] as? String ?? "folder", group)
        }
        self.folders = folders
    }

    /// `actions` without what only a Debug build has (its handlers are compiled out of Release):
    /// the listed actions, and the listed values of an action's enumeration argument.
    static func withoutDebugBuildEntries(_ actions: [[String: Any]], _ table: [String: Any]) -> [[String: Any]] {
        let dropped = Set(table["actions"] as? [String] ?? [])
        var droppedCases: [String: [(argument: String, value: String)]] = [:]
        for row in table["cases"] as? [[String: String]] ?? [] {
            guard let action = row["action"], let argument = row["argument"], let value = row["value"] else { continue }
            droppedCases[action, default: []].append((argument, value))
        }
        return actions.compactMap { row in
            guard let id = row["id"] as? String, !dropped.contains(id) else { return nil }
            guard let cases = droppedCases[id], var arguments = row["arguments"] as? [[String: Any]] else { return row }
            for index in arguments.indices {
                guard var kind = arguments[index]["kind"] as? [String: Any], let values = kind["enumeration"] as? [[String: Any]] else { continue }
                let name = arguments[index]["name"] as? String
                kind["enumeration"] = values.filter { value in
                    !cases.contains { $0.argument == name && $0.value == value["value"] as? String }
                }
                arguments[index]["kind"] = kind
            }
            var copy = row
            copy["arguments"] = arguments
            return copy
        }
    }

    // MARK: - Values

    private static func ids(_ value: Any?) -> [ActionID] {
        (value as? [String] ?? []).map(ActionID.init(rawValue:))
    }

    private static func idMap(_ value: Any?) -> [ActionID: ActionID] {
        var map: [ActionID: ActionID] = [:]
        for (key, target) in value as? [String: String] ?? [:] { map[ActionID(rawValue: key)] = ActionID(rawValue: target) }
        return map
    }

    static func shortcut(_ value: Any?) -> Shortcut? {
        guard let wire = value as? [String: Any], let key = wire["key"] as? String else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for name in wire["modifiers"] as? [String] ?? [] {
            switch name {
            case "ctrl": modifiers.insert(.control)
            case "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd": modifiers.insert(.command)
            default: break
            }
        }
        return Shortcut(key, modifiers: modifiers)
    }

    private static func decision(_ value: Any?) -> SurfaceDecision? {
        if let text = value as? String, text == "offered" { return .offered }
        guard let exempt = (value as? [String: String])?["exempt"], let reason = SurfaceExemption(rawValue: exempt) else { return nil }
        return .exempt(reason)
    }

    private static let groupsByName: [String: MenuGroup] = Dictionary(uniqueKeysWithValues: MenuGroup.allCases.map { (String(describing: $0), $0) })
    private static let contextNames: [String: ActionContext] = Dictionary(uniqueKeysWithValues: ActionContext.keyNames.map { ($0.1, $0.0) })
    private static let surfaceNames: [String: ActionSurfaces] = ["palette": .palette, "keyboard": .keyboard, "menu": .menu, "contextMenu": .contextMenu]

    private static func placement(_ value: [String: Any]) -> ContextMenuPlacement? {
        guard let context = (value["context"] as? String).flatMap(ActionMenuContext.init(rawValue:)),
              let group = (value["group"] as? String).flatMap({ groupsByName[$0] }),
              let rank = value["rank"] as? Int
        else { return nil }
        let style: MenuPlacementStyle = switch value["style"] as? String {
        case "choices": .choices
        case "submenu": .submenu
        default: .item
        }
        return ContextMenuPlacement(
            context, group, rank, style: style,
            parent: (value["parent"] as? String).map(ActionID.init(rawValue:)),
            folder: (value["folder"] as? String).flatMap(MenuFolder.init(rawValue:)),
            label: value["label"] as? String)
    }

    private static func cases(_ value: Any?) -> [ActionEnumCase] {
        (value as? [[String: String]] ?? []).map { ActionEnumCase(value: $0["value"] ?? "", title: $0["title"] ?? "") }
    }

    private static func argument(_ value: [String: Any]) -> ActionArgument? {
        guard let name = value["name"] as? String else { return nil }
        let kind: ActionArgumentKind
        switch value["kind"] {
        case let text as String where text == "bool": kind = .bool
        case let text as String where text == "string": kind = .string
        case let object as [String: Any]:
            if object.keys.contains("int") {
                let range = object["int"] as? [String: Int]
                kind = .int(range.flatMap { r in r["min"].flatMap { min in r["max"].map { min...$0 } } })
            } else if let values = object["enumeration"] {
                kind = .enumeration(cases(values))
            } else if let target = (object["target"] as? String).flatMap(ActionTargetKind.init(rawValue:)) {
                kind = .target(target)
            } else {
                return nil
            }
        default: return nil
        }
        var suggestions: ActionSuggestions?
        if let wire = value["suggestions"] as? [String: Any], let source = wire["source"] as? String {
            suggestions = ActionSuggestions(source: source, pinned: cases(wire["pinned"]), otherTitle: wire["otherTitle"] as? String,
                                            allowsMultiple: wire["allowsMultiple"] as? Bool ?? false)
        }
        var argument = ActionArgument(name: name, title: value["title"] as? String ?? name, kind: kind,
                                      isRequired: value["isRequired"] as? Bool ?? false, suggestions: suggestions)
        argument.isTargetName = value["isTargetName"] as? Bool ?? false
        argument.isTargetDescription = value["isTargetDescription"] as? Bool ?? false
        argument.isSuppliedByTarget = value["isSuppliedByTarget"] as? Bool ?? false
        argument.isAskedInPalette = value["isAskedInPalette"] as? Bool ?? false
        return argument
    }

    static func descriptor(_ value: [String: Any]) -> ActionDescriptor? {
        guard let id = value["id"] as? String, let category = (value["category"] as? String).flatMap(ActionCategory.init(rawValue:)),
              let wirePlan = value["surfacePlan"] as? [String: Any], let palette = decision(wirePlan["palette"])
        else {
            log.fault("action catalog row \(String(describing: value["id"]), privacy: .public) does not decode")
            return nil
        }
        var plan = ActionSurfacePlan(
            palette: palette, cli: decision(wirePlan["cli"]),
            contextMenus: (wirePlan["contextMenus"] as? [[String: Any]] ?? []).compactMap(placement),
            contextMenuExemption: (wirePlan["contextMenuExemption"] as? String).flatMap(SurfaceExemption.init(rawValue:)),
            mcpExemption: (wirePlan["mcpExemption"] as? String).flatMap(SurfaceExemption.init(rawValue:)))
        plan.palette = palette
        var surfaces: ActionSurfaces = []
        for name in value["surfaces"] as? [String] ?? [] { surfaces.formUnion(surfaceNames[name] ?? []) }
        var requires: ActionContext = []
        for name in value["requires"] as? [String] ?? [] { requires.formUnion(contextNames[name] ?? []) }
        var descriptor = ActionDescriptor(
            id: ActionID(rawValue: id), title: value["title"] as? String ?? id, description: value["description"] as? String,
            keywords: value["keywords"] as? [String] ?? [], defaultShortcut: shortcut(value["defaultShortcut"]),
            shortcutLabel: value["shortcutLabel"] as? String,
            shortcutFamily: (value["shortcutFamily"] as? String) == "digits" ? .digits : nil,
            category: category, symbol: value["symbol"] as? String ?? "command", surfaces: surfaces, requires: requires,
            arguments: (value["arguments"] as? [[String: Any]] ?? []).compactMap(argument),
            targets: (value["targets"] as? [String] ?? []).compactMap(ActionTargetKind.init(rawValue:)),
            cliName: value["cliName"] as? String, mainMenu: (value["mainMenu"] as? String).flatMap(ActionMainMenu.init(rawValue:)),
            isDebugOnly: value["isDebugOnly"] as? Bool ?? false, destructive: value["isDestructive"] as? Bool ?? false,
            startsTerminal: value["startsTerminal"] as? Bool ?? false, surfacePlan: plan)
        // The init derives these from the rest; the catalog already holds the derived values.
        descriptor.surfacePlan = plan
        descriptor.hint = value["hint"] as? String
        if let chord = value["defaultChord"] as? [String: Any], let first = shortcut(chord["first"]), let second = shortcut(chord["second"]) {
            descriptor.defaultChord = ShortcutChord(first, second)
        }
        descriptor.waitsForResult = value["waitsForResult"] as? Bool ?? false
        descriptor.focuses = value["focuses"] as? Bool ?? false
        descriptor.isPersonOnly = value["isPersonOnly"] as? Bool ?? false
        descriptor.isGlobalHotKey = value["isGlobalHotKey"] as? Bool ?? false
        descriptor.waitsForPerson = value["waitsForPerson"] as? Bool ?? false
        descriptor.waitsForKeyedCreate = value["waitsForKeyedCreate"] as? Bool ?? false
        descriptor.opensWorkspaceContent = value["opensWorkspaceContent"] as? Bool ?? false
        return descriptor
    }

    static func binding(_ value: [String: Any]) -> KeyBinding? {
        guard let command = value["command"] as? String else { return nil }
        let keys = (value["keys"] as? [[String: Any]] ?? []).compactMap(shortcut)
        var arguments: [String: ActionValue] = [:]
        for (name, wire) in value["arguments"] as? [String: [String: Any]] ?? [:] {
            if let text = wire["string"] as? String { arguments[name] = .string(text) }
            else if let number = wire["int"] as? Int { arguments[name] = .int(number) }
            else if let flag = wire["bool"] as? Bool { arguments[name] = .bool(flag) }
        }
        var when: WhenClause?
        if let text = value["when_text"] as? String {
            do { when = try WhenClause.parse(text) } catch {
                log.fault("default binding for \(command, privacy: .public): when clause does not parse")
                return nil
            }
        }
        return KeyBinding(keys: keys, command: ActionID(rawValue: command), argument: value["argument"] as? String,
                          arguments: arguments, when: when)
    }
}
