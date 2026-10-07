public import CmuxMobileHost
public import CmuxMobileWire
import Foundation

/// The harnesses this Mac offers phones (c8-composer.md 3), from acpmux's
/// `_acpmux/harnesses` (names, display names, `unavailable` and probe
/// errors) and `_acpmux/models` (the ACP harnesses with their models).
/// Terminal harnesses have no ACP session and peer harnesses run on another
/// machine, so neither is offered. Pure.
public enum AcpmuxCatalog {
    public static func agents(harnesses: JSONValue, models: JSONValue) -> [MobileAgent] {
        let profiles = harnesses["harnesses"]?.objectValue ?? [:]
        let preferred = harnesses["defaultHarness"]?.stringValue
        var agents: [MobileAgent] = []
        for entry in models["harnesses"]?.acpmuxItems ?? [] {
            guard let id = entry["harness"]?.stringValue, !id.isEmpty, entry["peer"] == nil else { continue }
            let profile = profiles[id]
            let offered: [MobileAgentModel] = (entry["models"]?.acpmuxItems ?? []).compactMap { model in
                guard let modelID = model["id"]?.stringValue, model["unavailable"] == nil else { return nil }
                return MobileAgentModel(id: modelID, label: model["name"]?.stringValue ?? modelID)
            }
            let reason = profile?["unavailable"]?.stringValue ?? profile?["probeError"]?.stringValue
                ?? entry["probeError"]?.stringValue
            agents.append(MobileAgent(id: id, name: profile?["displayName"]?.stringValue ?? id, models: offered,
                                      defaultModel: offered.first?.id, unavailable: reason))
        }
        return agents.sorted { lhs, rhs in
            if (lhs.id == preferred) != (rhs.id == preferred) { return lhs.id == preferred }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension JSONValue {
    /// The elements of an array, else none.
    var acpmuxItems: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }
}
