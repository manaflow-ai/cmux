import CmuxNextActions
import CmuxNextSettings
import Foundation

/// One argument of an action's schema, in wire form. Built on the main
/// actor from `ActionArgument` so the socket can validate off the main actor.
public struct ControlArgumentInfo: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case string
        case int
        case bool
        case enumeration = "enum"
        case target
    }

    public struct Choice: Sendable, Hashable {
        public var value: String
        public var title: String

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public var name: String
    public var title: String
    public var kind: Kind
    public var isRequired: Bool
    public var choices: [Choice]
    public var range: ClosedRange<Int>?
    /// For `.target`: the target kind's CLI prefix (`workspace-group`).
    public var targetKind: String?

    public init(name: String, title: String, kind: Kind, isRequired: Bool, choices: [Choice] = [], range: ClosedRange<Int>? = nil, targetKind: String? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.choices = choices
        self.range = range
        self.targetKind = targetKind
    }

    var json: JSONValue {
        var members: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "kind": .string(kind.rawValue),
            "required": .bool(isRequired),
        ]
        if !choices.isEmpty {
            members["choices"] = .array(choices.map { .object(["value": .string($0.value), "title": .string($0.title)]) })
        }
        if let range {
            members["min"] = JSONValue(range.lowerBound)
            members["max"] = JSONValue(range.upperBound)
        }
        if let targetKind { members["target_kind"] = .string(targetKind) }
        return .object(members)
    }
}

/// One action in wire form: everything `action.list` reports.
public struct ControlActionInfo: Sendable, Hashable {
    public var id: String
    public var title: String
    /// What the action does and returns (`ActionDescriptor.description`), or nil.
    public var description: String?
    public var category: String
    public var categoryTitle: String
    public var cliName: String
    public var symbol: String
    public var keywords: [String]
    /// Display form of the effective shortcut (`⇧⌘P`), or nil.
    public var shortcut: String?
    /// cmux.json form of the effective shortcut (`cmd+shift+p`), or nil.
    public var shortcutConfig: String?
    public var arguments: [ControlArgumentInfo]
    /// Target kinds as CLI prefixes (`tab`, `tab-group`), first is the default.
    public var targets: [String]
    /// Required context bits (`ActionContext.rawValue`).
    public var requiresMask: UInt32
    /// Names of the required context facts, for display.
    public var requires: [String]
    public var isBound: Bool
    public var isDebugOnly: Bool
    public var mainMenu: String?
    /// Why the action cannot run in this build, when it is bound as
    /// unavailable (snapshot for `action.list`). An action with a reason
    /// reaches the executor even out of context, which re-reads the live
    /// reason and reports it before the context check.
    public var unavailableReason: String?
    /// The feature an administrator turned off for this action
    /// (`DisabledFeatures`): `action.list` leaves it out and resolving it
    /// answers `feature.disabled`.
    public var disabledFeature: String?
    /// Surface decisions (`ActionDescriptor.surfacePlan`): `palette`, `cli`,
    /// `context_menu`, `mcp` map to `offered` or an exemption reason.
    public var surfaces: [String: String] = [:]
    /// The right-click menus that show the action (`ActionMenuContext`).
    public var contextMenus: [String] = []
    /// Destructive: `action.run` requires `confirm: true`
    /// (`ActionDescriptor.isDestructive`).
    public var isDestructive = false
    /// Starts a terminal (`ActionDescriptor.startsTerminal`): `action.run`
    /// with `wait` uses the terminal start deadline.
    public var startsTerminal = false
    /// Has a purpose outside the GUI: the CLI offers it by `cliName`
    /// (`ActionDescriptor.cli`).
    public var isCLI = false
    /// The CLI waits for the work's result (`ActionDescriptor.waitsForResult`);
    /// `action.run` with `wait` then gets the result deadline.
    public var waitsForResult = false
    /// The run waits for a person's answer (`ActionDescriptor.waitsForPerson`);
    /// `action.run` with `wait` then gets the person deadline.
    public var waitsForPerson = false
    /// A keyed daemon create that asks again when its reply is late
    /// (`ActionDescriptor.waitsForKeyedCreate`): `action.run` with `wait`
    /// gets `ActionRunLimit.keyedCreate`.
    public var waitsForKeyedCreate = false
    /// The action's purpose is a view change (`ActionDescriptor.focuses`):
    /// it focuses or shows even when run from the CLI without `focus`.
    public var focuses = false

    public init(
        id: String, title: String, category: String, categoryTitle: String, cliName: String, symbol: String,
        keywords: [String], shortcut: String?, shortcutConfig: String?, arguments: [ControlArgumentInfo],
        targets: [String], requiresMask: UInt32, requires: [String], isBound: Bool, isDebugOnly: Bool, mainMenu: String?
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.categoryTitle = categoryTitle
        self.cliName = cliName
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
        self.shortcutConfig = shortcutConfig
        self.arguments = arguments
        self.targets = targets
        self.requiresMask = requiresMask
        self.requires = requires
        self.isBound = isBound
        self.isDebugOnly = isDebugOnly
        self.mainMenu = mainMenu
    }

    func json(contextMask: UInt32, debugActionsAvailable: Bool) -> JSONValue {
        let words = cliName.split(separator: " ", maxSplits: 1).map(String.init)
        var members: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "category": .string(category),
            "category_title": .string(categoryTitle),
            "cli_name": .string(cliName),
            "noun": .string(words.first ?? cliName),
            "verb": .string(words.count > 1 ? words[1] : ""),
            "symbol": .string(symbol),
            "keywords": .array(keywords.map(JSONValue.string)),
            "shortcut": shortcut.map(JSONValue.string) ?? .null,
            "shortcut_config": shortcutConfig.map(JSONValue.string) ?? .null,
            "arguments": .array(arguments.map(\.json)),
            "targets": .array(targets.map(JSONValue.string)),
            "requires": .array(requires.map(JSONValue.string)),
            "available": .bool(isAvailable(contextMask: contextMask, debugActionsAvailable: debugActionsAvailable)),
            "bound": .bool(isBound),
            "debug_only": .bool(isDebugOnly),
            "destructive": .bool(isDestructive),
            "starts_terminal": .bool(startsTerminal),
            "cli": .bool(isCLI),
            "waits_for_result": .bool(waitsForResult),
            "waits_for_person": .bool(waitsForPerson),
            "focuses": .bool(focuses),
        ]
        if let mainMenu { members["main_menu"] = .string(mainMenu) }
        if let description { members["description"] = .string(description) }
        if let unavailableReason { members["unavailable_reason"] = .string(unavailableReason) }
        members.merge(contextGap(contextMask: contextMask)) { current, _ in current }
        if !surfaces.isEmpty {
            var surfaceMembers = surfaces.mapValues(JSONValue.string)
            surfaceMembers["context_menus"] = .array(contextMenus.map(JSONValue.string))
            members["surfaces"] = .object(surfaceMembers)
        }
        return .object(members)
    }

    /// Why `available` is false in this context, for `action.list` and
    /// `action.describe`: the context facts it lacks (`missing_context`), the
    /// target kinds whose explicit target supplies them (`available_with_target`:
    /// a `machine:` target stands in for a focused Cloud workspace), and one
    /// sentence saying so (`context_reason`). Empty when nothing is missing.
    func contextGap(contextMask: UInt32) -> [String: JSONValue] {
        let missing = ActionContext(rawValue: requiresMask & ~contextMask)
        guard !missing.isEmpty else { return [:] }
        let names = ActionContext.keyNames.filter { missing.contains($0.0) }.map(\.1)
        guard !names.isEmpty else { return [:] }
        let supplying = targets.filter { kind in
            ActionTargetKind(rawValue: kind).map { ActionContext.implied(byTargetKind: $0).isSuperset(of: missing) } ?? false
        }
        let listed = names.joined(separator: ", ")
        var members: [String: JSONValue] = ["missing_context": .array(names.map(JSONValue.string))]
        if let kind = supplying.first {
            members["available_with_target"] = .array(supplying.map(JSONValue.string))
            let format = String(localized: "control.action.needsContextOrTarget",
                                defaultValue: "Needs %1$@ in the focused window, or pass --target %2$@:<id>.", bundle: .module)
            members["context_reason"] = .string(String(format: format, listed, kind))
        } else {
            let format = String(localized: "control.action.needsContext", defaultValue: "Needs %@ in the focused window.", bundle: .module)
            members["context_reason"] = .string(String(format: format, listed))
        }
        return members
    }

    /// Whether the action applies in the current context (not whether its
    /// handler's `isEnabled` passes; that is only known when it runs).
    public func isAvailable(contextMask: UInt32, debugActionsAvailable: Bool) -> Bool {
        if isDebugOnly && !debugActionsAvailable { return false }
        return contextMask & requiresMask == requiresMask
    }
}

/// Immutable snapshot of the action registry for the socket. The App bridge
/// replaces it when bindings, overrides, or the catalog change, and updates
/// `contextMask` alone on focus changes, so `action.list` and
/// `action.describe` never touch the main actor.
public struct ControlCatalog: Sendable {
    public var actions: [ControlActionInfo]
    public var contextMask: UInt32
    /// Legacy action IDs folded into canonical IDs.
    public var aliases: [String: String]
    public var debugActionsAvailable: Bool
    /// Every target kind's CLI prefix, so a mistyped `kind:` is reported
    /// instead of being read as part of an id.
    public var targetKinds: [String]
    private var indexByID: [String: Int]
    private var indexByCLIName: [String: Int]

    public init(
        actions: [ControlActionInfo],
        contextMask: UInt32 = 0,
        aliases: [String: String] = [:],
        targetKinds: [String] = [],
        debugActionsAvailable: Bool
    ) {
        self.actions = actions
        self.targetKinds = targetKinds
        self.contextMask = contextMask
        self.aliases = aliases
        self.debugActionsAvailable = debugActionsAvailable
        var byID: [String: Int] = [:]
        var byCLI: [String: Int] = [:]
        for (index, action) in actions.enumerated() {
            byID[action.id] = byID[action.id] ?? index
            byCLI[action.cliName] = byCLI[action.cliName] ?? index
        }
        indexByID = byID
        indexByCLIName = byCLI
    }

    public static let empty = ControlCatalog(actions: [], debugActionsAvailable: false)

    /// Resolves an action ID, legacy alias, or CLI name (`tab-group create`,
    /// also with extra spaces or `tab-group.create`).
    public func resolve(_ name: String) -> ControlActionInfo? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let index = indexByID[trimmed] ?? aliases[trimmed].flatMap({ indexByID[$0] }) {
            return actions[checked: index]
        }
        let spaced = trimmed.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        if let index = indexByCLIName[spaced] { return actions[checked: index] }
        if let index = indexByCLIName[Self.renamedCLIName(spaced)] { return actions[checked: index] }
        return nil
    }

    /// Resolves a CLI name only (`tab-group create`, extra spaces allowed).
    public func resolveCLIName(_ name: String) -> ControlActionInfo? {
        let spaced = name.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return indexByCLIName[spaced].flatMap { actions[checked: $0] }
    }

    /// The current name of a CLI name from before Rooms became Spaces
    /// (`room create`, `workspace move-to-room`); every other name as is.
    static func renamedCLIName(_ name: String) -> String {
        name.replacingOccurrences(of: "room", with: "space")
    }
    func isAvailable(_ action: ControlActionInfo) -> Bool {
        action.isAvailable(contextMask: contextMask, debugActionsAvailable: debugActionsAvailable)
    }

    /// Availability for a run with an explicit target, which stands in for
    /// the facts it implies (`ActionContext.implied(byTargetKind:)`) and
    /// leaves the facts only the App can read to the registry
    /// (`deferredToRegistry(byTargetKind:)`).
    func isAvailable(_ action: ControlActionInfo, target: ControlTargetRef?) -> Bool {
        let kind = target.flatMap { ActionTargetKind(rawValue: $0.kind) }
        let mask = contextMask | ActionContext.implied(byTargetKind: kind).rawValue
            | Self.deferredToRegistry(byTargetKind: kind).rawValue
        return action.isAvailable(contextMask: mask, debugActionsAvailable: debugActionsAvailable)
    }

    /// The facts a pane or tab target may bring that only the App knows live:
    /// whether it shows an agent chat (`agentPaneFocused`, so `cmux agent
    /// set-model --target pane:<id>` runs with no chat focused) and whether it
    /// sits on a canvas screen (`canvasLayout`). This snapshot can lag the
    /// App's tabs (at startup, or just after a chat opened), so `action.run`
    /// does not decide them here. The registry reads them on the main actor
    /// (`ActionRegistry.targetContext`) and refuses a target without them as
    /// `unavailable` before the handler runs.
    static func deferredToRegistry(byTargetKind kind: ActionTargetKind?) -> ActionContext {
        switch kind {
        case .pane, .tab: .decidedByPaneOrTabTarget
        default: []
        }
    }

    func json(_ action: ControlActionInfo) -> JSONValue {
        action.json(contextMask: contextMask, debugActionsAvailable: debugActionsAvailable)
    }
}
