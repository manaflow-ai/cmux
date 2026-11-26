public import Foundation
public import CmuxNextActions

/// Where an app came from (`apps-list` `source`).
public nonisolated enum AppSource: String, Sendable, Hashable, CaseIterable {
    /// A first-party app on the deployment's default list: installed for
    /// everyone, its required scopes granted without a consent sheet.
    case `default`
    /// Installed by the user from the App Store.
    case user
    /// Shipped inside cmux, opt-in.
    case bundled
    /// A `local/` development app.
    case local
}

/// One app in the supervisor's install mirror (one `apps-list` entry, and
/// the reply of `apps-set`). The daemon owns every field; the client only
/// renders it.
public nonisolated struct AppRecord: Sendable, Hashable, Identifiable {
    /// Which automation paths still reach a hidden app (V9; default all true).
    public struct HiddenAccess: Sendable, Hashable {
        public var cli: Bool
        public var mcp: Bool
        public var automations: Bool

        public init(cli: Bool = true, mcp: Bool = true, automations: Bool = true) {
            self.cli = cli
            self.mcp = mcp
            self.automations = automations
        }
    }

    public var id: String
    public var version: String
    public var tier: AppStoreTier
    public var installed: Bool
    public var enabled: Bool
    public var hidden: Bool
    public var hiddenAccess: HiddenAccess
    public var source: AppSource
    /// Granted scopes.
    public var grants: Set<String>
    public var sandboxed: Bool
    public var manifest: AppManifest
    /// The daemon has the package (`available`).
    public var available: Bool
    /// The package directory on this Mac (`bundle_dir`; apps commands are
    /// local only), for icons and scene images.
    public var bundleDirectory: URL?
    /// The mirror revision after the commit (`apps-set` replies only).
    public var revision: UInt64?
    /// The app's catalog ops on the palette surface (`commands`), run with `apps-run`.
    public var commands: [Command]
    /// The app's deployed instance (`instance`), for apps with a manifest `deploy` block.
    public var instance: AppInstance?
    /// The web panes the daemon lets this client host (`web_pages`, `render: web`).
    public var webPages: [AppWebPage] = []
    /// The app's `contributes.keybindings` (`keybindings`), in keybindings.json form: the daemon
    /// already turned an own op into `app.command.run` `{app, command}`.
    public var keybindings: [Keybinding] = []

    /// One contributed binding: `keys` are the strokes (`["ctrl+k", "s"]`).
    public struct Keybinding: Sendable, Hashable {
        public var keys: [String]
        public var command: String
        public var when: String?
        public var args: [String: AppJSON]

        public init(keys: [String], command: String, when: String? = nil, args: [String: AppJSON] = [:]) {
            self.keys = keys
            self.command = command
            self.when = when
            self.args = args
        }
    }

    /// One palette command of an app: a catalog op of its own family.
    public struct Command: Sendable, Hashable, Identifiable {
        /// The full op name (`coderouter.app.connect_account`).
        public var op: String
        public var title: AppLocalizedText
        public var when: String?
        /// The op's default shortcuts (catalog `keyboard`, `commands[].keys`).
        public var keys: [Key]
        /// Single browser-page keys (`page_keys`), with `cmux.keys` overrides applied by the daemon.
        public var pageKeys: [String]
        /// The raw catalog predicate for each page key (`page_key_when`).
        public var pageKeyWhen: [String: String] {
            didSet { pageKeyClauses = Self.parsed(pageKeyWhen) }
        }
        /// `pageKeyWhen` parsed once (here, not on each key event); a predicate that does not parse is absent.
        private var pageKeyClauses: [String: WhenClause]
        public var id: String { op }

        public init(op: String, title: AppLocalizedText, when: String? = nil, keys: [Key] = [], pageKeys: [String] = [], pageKeyWhen: [String: String] = [:]) {
            self.op = op
            self.title = title
            self.when = when
            self.keys = keys
            self.pageKeys = pageKeys
            self.pageKeyWhen = pageKeyWhen
            pageKeyClauses = Self.parsed(pageKeyWhen)
        }

        private static func parsed(_ when: [String: String]) -> [String: WhenClause] {
            when.compactMapValues { try? WhenClause.parse($0) }
        }

        /// Whether a bare page key runs this command under the live context.
        public func answers(pageKey character: String, shift: Bool) -> Bool {
            answers(pageKey: character, shift: shift, context: KeyContext(["browserFocused": .bool(true)]))
        }

        public func answers(pageKey character: String, shift: Bool, context: KeyContext) -> Bool {
            let key = shift ? "shift+\(character)" : character
            guard pageKeys.contains(key) else { return false }
            guard let clause = pageKeyClauses[key] else {
                return pageKeyWhen[key] == nil
            }
            return clause.evaluate(context)
        }

        /// One default shortcut: one chord (`cmd+shift+r`) and its context (`browserFocused`).
        public struct Key: Sendable, Hashable {
            public var key: String
            public var when: String?

            public init(key: String, when: String? = nil) {
                self.key = key
                self.when = when
            }
        }

        /// `name` names this command: the full op (`coderouter.app.connect_account`),
        /// or the last segment in either case style (`connect_account`, `connectAccount`).
        public func matches(_ name: String) -> Bool {
            if op == name { return true }
            let last = op.split(separator: ".").last.map(String.init) ?? op
            let snake = name.reduce(into: "") { out, character in
                if character.isUppercase, !out.isEmpty { out.append("_") }
                out.append(Character(character.lowercased()))
            }
            return last == name || last == snake
        }
    }

    public init(manifest: AppManifest, tier: AppStoreTier, installed: Bool, enabled: Bool = true, hidden: Bool = false,
                hiddenAccess: HiddenAccess = HiddenAccess(), source: AppSource, grants: Set<String> = [], sandboxed: Bool = false) {
        id = manifest.id
        version = manifest.version
        self.tier = tier
        self.installed = installed
        self.enabled = enabled
        self.hidden = hidden
        self.hiddenAccess = hiddenAccess
        self.source = source
        self.grants = grants
        self.sandboxed = sandboxed
        self.manifest = manifest
        available = true
        bundleDirectory = nil
        commands = []
    }

    /// Installed and enabled: it runs and answers granted calls.
    public var isActive: Bool { installed && enabled }
    /// Active and not hidden: its sidebar, palette and menu presence shows.
    public var isVisible: Bool { isActive && !hidden }
    /// Installed for everyone by the deployment (no consent, no remove).
    public var isDefault: Bool { source == .default }
    public func isGranted(_ scope: String) -> Bool { grants.contains(scope) }
    /// Part of cmux itself (``AppStoreListing/builtInIDs``): no Remove, no sandbox.
    public var isBuiltIn: Bool { tier == .firstParty && AppStoreListing.builtInIDs.contains(id) }

    /// Decodes one wire record; nil when a required field is missing.
    public init?(json: AppJSON) {
        guard let manifest = json["manifest"].flatMap(AppManifest.init(json:)), let id = json["id"]?.stringValue,
              id == manifest.id else { return nil }
        self.id = id
        self.manifest = manifest
        version = json["version"]?.stringValue ?? manifest.version
        tier = json["tier"]?.stringValue.flatMap(AppStoreTier.init(rawValue:)) ?? AppStoreTier.local(manifest)
        installed = json["installed"]?.boolValue ?? false
        enabled = json["enabled"]?.boolValue ?? true
        hidden = json["hidden"]?.boolValue ?? false
        let access = json["hidden_access"]
        hiddenAccess = HiddenAccess(cli: access?["cli"]?.boolValue ?? true, mcp: access?["mcp"]?.boolValue ?? true,
                                       automations: access?["automations"]?.boolValue ?? true)
        source = json["source"]?.stringValue.flatMap(AppSource.init(rawValue:)) ?? .user
        grants = Set(json["grants"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        sandboxed = json["sandboxed"]?.boolValue ?? false
        available = json["available"]?.boolValue ?? true
        bundleDirectory = json["bundle_dir"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
        revision = json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) }
        instance = AppInstance(json: json["instance"])
        webPages = json["web_pages"]?.arrayValue?.compactMap(AppWebPage.init(json:)) ?? []
        keybindings = (json["keybindings"]?.arrayValue ?? []).compactMap { entry in
            guard let key = entry["key"]?.stringValue, let command = entry["command"]?.stringValue else { return nil }
            return Keybinding(keys: key.split(separator: " ").map(String.init), command: command,
                              when: entry["when"]?.stringValue, args: entry["args"]?.objectValue ?? [:])
        }
        commands = (json["commands"]?.arrayValue ?? []).compactMap { entry in
            guard let op = entry["op"]?.stringValue else { return nil }
            let keys = (entry["keys"]?.arrayValue ?? []).compactMap { key in
                key["key"]?.stringValue.map { Command.Key(key: $0, when: key["when"]?.stringValue) }
            }
            let pageKeys = entry["page_keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let pageKeyWhen = entry["page_key_when"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            return Command(op: op, title: AppLocalizedText(json: entry["title"]) ?? AppLocalizedText(op), when: entry["when"]?.stringValue,
                           keys: keys, pageKeys: pageKeys, pageKeyWhen: pageKeyWhen)
        }
    }

    /// The wire shape (the fake transport answers with it).
    public var json: AppJSON {
        [
            "id": .string(id), "version": .string(version), "tier": .string(tier.rawValue), "installed": .bool(installed),
            "enabled": .bool(enabled), "hidden": .bool(hidden), "source": .string(source.rawValue), "sandboxed": .bool(sandboxed),
            "hidden_access": ["cli": .bool(hiddenAccess.cli), "mcp": .bool(hiddenAccess.mcp), "automations": .bool(hiddenAccess.automations)],
            "grants": .array(grants.sorted().map(AppJSON.string)), "manifest": manifest.raw, "available": .bool(available),
            "bundle_dir": bundleDirectory.map { .string($0.path) } ?? .null,
            "revision": revision.map { .number(Double($0)) } ?? .null,
            "commands": .array(commands.map { command in
                ["op": .string(command.op), "title": .string(command.title.english),
                 "keys": .array(command.keys.map { ["key": .string($0.key), "when": $0.when.map(AppJSON.string) ?? .null] }),
                 "page_keys": .array(command.pageKeys.map(AppJSON.string)),
                 "page_key_when": .object(command.pageKeyWhen.mapValues(AppJSON.string))]
            }),
            "keybindings": .array(keybindings.map { binding in
                ["key": .string(binding.keys.joined(separator: " ")), "command": .string(binding.command),
                 "when": binding.when.map(AppJSON.string) ?? .null, "args": .object(binding.args)]
            }),
        ]
    }
}
