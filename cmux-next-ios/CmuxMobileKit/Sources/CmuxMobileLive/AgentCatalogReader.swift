import CmuxAgentBrands
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

extension AgentCatalog {
    /// The catalog from acpmux's `_acpmux/harnesses` reply (`harnesses` keyed by id, `defaultHarness`)
    /// and, when the Mac answered it, `_acpmux/models` (`harnesses: [{harness, models}]`).
    ///
    /// As the Mac's New Agent Chat: terminal harnesses (they run in a terminal tab) are not chat agents;
    /// a launcher that can't run (`unavailable`) is Unavailable with its reason, a failed probe alone is
    /// not. A phone also never starts the families acpmux refuses to a remote connection.
    public init(harnesses reply: JSONValue, models: JSONValue? = nil) {
        guard case .object(let entries)? = reply["harnesses"] else {
            self.init(harnesses: [])
            return
        }
        let defaultID = reply["defaultHarness"]?.stringValue
        var modelLists: [String: [AgentModelChoice]] = [:]
        for row in models?["harnesses"]?.arrayValue ?? [] {
            guard let id = row["harness"]?.stringValue else { continue }
            // The agent's current models (`topModels`); the rest are older releases. With no
            // list every model is current.
            let top = row["topModels"]?.arrayValue?.compactMap(\.stringValue)
            modelLists[id] = (row["models"]?.arrayValue ?? []).compactMap { model in
                guard let modelID = model["id"]?.stringValue, !modelID.isEmpty else { return nil }
                let name = model["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? modelID
                return AgentModelChoice(id: modelID, name: name, unavailableReason: model["unavailable"]?.stringValue,
                                        efforts: (model["efforts"]?.arrayValue ?? []).compactMap(\.stringValue),
                                        defaultEffort: model["defaultEffort"]?.stringValue,
                                        shortName: model["shortName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                                        aliases: (model["aliases"]?.arrayValue ?? []).compactMap(\.stringValue),
                                        isCurrent: top.map { $0.contains(modelID) } ?? true)
            }
        }
        var choices: [AgentHarnessChoice] = []
        for (id, entry) in entries {
            if entry["kind"]?.stringValue == "terminal" { continue }
            // acpmux `pickerHidden`: the cmux model router profile, Claude's automatic fallback.
            if case .bool(true)? = entry["pickerHidden"] { continue }
            let family = entry["family"]?.stringValue ?? id
            // acpmux also refuses a profile whose command runs Codex or opencode under
            // another family name (`web_modes.rs` `refused_families`).
            let runsRefused = (entry["argv"]?.arrayValue ?? []).compactMap(\.stringValue).contains { arg in
                let name = (arg as NSString).lastPathComponent.lowercased()
                return Self.refusedFamilies.contains { name.hasPrefix($0) } || arg.contains("codex-acp")
            }
            // A Mac that says what a phone may start (acpmux `remote`) decides it: the Codex
            // bridge starts in its asking mode. An older Mac keeps the family rule.
            let remote = entry["remote"]
            let reason: String? = if case .bool(let startable)? = remote?["startable"] {
                startable ? Self.launcherReason(entry["unavailable"])
                    : remote?["reason"]?.stringValue.map { "Not available from here: \($0)" } ?? Self.refusedReason
            } else if Self.refusedFamilies.contains(family) || runsRefused {
                Self.refusedReason
            } else {
                Self.launcherReason(entry["unavailable"])
            }
            let start = entry["start"]?["model"]?.stringValue ?? entry["model"]?.stringValue
            // What its chats report (acpmux `reported`): mode names, and its options.
            let reported = entry["reported"]
            let reportedOptions = reported?["configOptions"]?.arrayValue ?? []
            // The effort option names the levels whatever a phone may set; the other options are
            // offered only when the Mac says a remote device may set them (`remoteSettable`, the
            // remote guard's rule: Fast mode is not, so a pill for it would do nothing).
            let options = reportedOptions.compactMap(Self.configChoice)
            let settable = Set(reportedOptions.compactMap { option -> String? in
                guard case .bool(true)? = option["remoteSettable"] else { return nil }
                return option["id"]?.stringValue
            })
            let modes = (reported?["modes"]?.arrayValue ?? []).compactMap { mode -> AgentSettingChoice? in
                guard let id = mode["id"]?.stringValue, !id.isEmpty else { return nil }
                return AgentSettingChoice(id: id, name: mode["name"]?.stringValue ?? AgentSettingChoice.name(for: id),
                                          detail: mode["description"]?.stringValue)
            }
            choices.append(AgentHarnessChoice(
                id: id, name: Self.displayName(id: id, family: family, entry: entry), family: family,
                isDefault: id == defaultID, unavailableReason: reason,
                models: modelLists[id] ?? [], defaultModel: start,
                askingModes: (remote?["modes"]?.arrayValue ?? []).compactMap(\.stringValue),
                startEffort: entry["start"]?["effort"]?.stringValue,
                reportedModes: modes,
                effortOption: options.first(where: \.isEffort),
                configOptions: options.filter { settable.contains($0.id) && Self.isOwnOption($0, family: family, hasModes: !modes.isEmpty) }
            ))
        }
        // The Mac's default first, then by name (the catalog is keyed, so unordered).
        choices.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        self.init(harnesses: choices, lastPicks: Self.lastPicks(reply["lastPicks"]))
    }

    /// One reported config option (ACP `configOptions[]`: a `select` with its choices, flat or in
    /// groups); nil for one with nothing to pick.
    static func configChoice(_ value: JSONValue) -> AgentConfigChoice? {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        if let type = value["type"]?.stringValue, type != "select" { return nil }
        var choices: [AgentSettingChoice] = []
        for entry in value["options"]?.arrayValue ?? [] {
            // A group (`{group, name, options}`) lists its choices inside.
            for choice in entry["options"]?.arrayValue ?? [entry] {
                guard let id = choice["value"]?.stringValue, !id.isEmpty, !choices.contains(where: { $0.id == id }) else { continue }
                choices.append(AgentSettingChoice(id: id, name: choice["name"]?.stringValue ?? AgentSettingChoice.name(for: id),
                                                  detail: choice["description"]?.stringValue))
            }
        }
        guard !choices.isEmpty else { return nil }
        return AgentConfigChoice(id: id, name: value["name"]?.stringValue ?? AgentSettingChoice.name(for: id),
                                 category: value["category"]?.stringValue, choices: choices)
    }

    /// An option with no picker of its own, as the Mac's composer lists them (`agentOptions.ts`
    /// `extraConfigOptions`): not the model, the effort or a mode, nor Codex's collaboration mode
    /// or the per-chat switches the Mac keeps out of the composer (session recap, suggestions).
    static func isOwnOption(_ option: AgentConfigChoice, family: String, hasModes: Bool) -> Bool {
        guard option.choices.count > 1, !option.isEffort else { return false }
        if option.id == "model" || option.category == "model" { return false }
        if hasModes, option.id == "mode" || option.category == "mode" { return false }
        if family == "codex", option.id == "collaboration_mode" || option.category == "collaboration_mode" { return false }
        return !["session-recap", "prompt-suggestions"].contains(option.id)
    }

    /// acpmux `lastPicks` (`{lastAgent?, global?: {harness, model}, folders: [{folder, harness, model}]}`).
    static func lastPicks(_ value: JSONValue?) -> AgentLastPicks? {
        guard let value, case .object = value else { return nil }
        func pick(_ v: JSONValue?) -> AgentLastPicks.Pick? {
            guard let harness = v?["harness"]?.stringValue, !harness.isEmpty else { return nil }
            return .init(harness: harness, model: v?["model"]?.stringValue)
        }
        var folders: [String: AgentLastPicks.Pick] = [:]
        for row in value["folders"]?.arrayValue ?? [] {
            if let folder = row["folder"]?.stringValue, let p = pick(row) { folders[folder] = p }
        }
        let picks = AgentLastPicks(lastAgent: value["lastAgent"]?.stringValue, global: pick(value["global"]), folders: folders)
        return picks.lastAgent == nil && picks.global == nil && picks.folders.isEmpty ? nil : picks
    }

    static func launcherReason(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text.isEmpty ? "Unavailable" : text }
        if let text = value["reason"]?.stringValue ?? value["message"]?.stringValue { return text }
        if case .bool(false) = value { return nil }
        if case .null = value { return nil }
        return "Unavailable"
    }

    /// A profile file's `displayName`, else the brand catalog's name for the id or family,
    /// else the id. A variant profile keeps its id visible (`Claude Code (claude-cr)`).
    static func displayName(id: String, family: String, entry: JSONValue) -> String {
        if let name = entry["displayName"]?.stringValue, !name.isEmpty { return name }
        let names = Dictionary(AgentBrandCatalog.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let name = names[id] { return name }
        if let name = names[family] { return "\(name) (\(id))" }
        return id
    }
}
