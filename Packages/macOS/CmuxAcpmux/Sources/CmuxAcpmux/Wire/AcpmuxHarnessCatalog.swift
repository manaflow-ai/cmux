import Foundation

/// Harness profiles and models the daemon can start, merged from `_acpmux/harnesses`
/// and `_acpmux/models`.
public struct AcpmuxHarnessCatalog: Sendable, Hashable {
    /// Available harnesses in display order (default first).
    public var harnesses: [Harness]
    /// The daemon's default harness, if configured.
    public var defaultHarness: String?

    /// One harness profile.
    public struct Harness: Sendable, Hashable, Identifiable {
        /// Profile name passed as `_meta.acpmux.harness`.
        public var name: String
        /// Family, for example `claude`.
        public var family: String?
        /// Why the profile cannot start, if it cannot.
        public var unavailableReason: String?
        /// Models the harness reports.
        public var models: [Model]
        /// The profile name.
        public var id: String { name }
    }

    /// One model choice.
    public struct Model: Sendable, Hashable, Codable, Identifiable {
        /// Model id passed to `session/set_model`.
        public var id: String
        /// Display name.
        public var name: String?
    }

    /// Creates an empty catalog.
    public init(harnesses: [Harness] = [], defaultHarness: String? = nil) {
        self.harnesses = harnesses
        self.defaultHarness = defaultHarness
    }

    /// Merges raw `_acpmux/harnesses` and `_acpmux/models` results.
    /// - Parameters:
    ///   - harnessesResult: The `_acpmux/harnesses` result.
    ///   - modelsResult: The `_acpmux/models` result, or `.null` when unavailable.
    public init(harnessesResult: JSONValue, modelsResult: JSONValue) {
        var modelsByHarness: [String: [Model]] = [:]
        for entry in modelsResult["harnesses"]?.arrayValue ?? [] {
            guard let name = entry["harness"]?.stringValue else { continue }
            modelsByHarness[name] = (entry["models"]?.arrayValue ?? []).compactMap { model in
                guard let id = model["id"]?.stringValue else { return nil }
                return Model(id: id, name: model["name"]?.stringValue)
            }
        }
        let defaultHarness = harnessesResult["defaultHarness"]?.stringValue
        var harnesses: [Harness] = []
        if case .object(let profiles)? = harnessesResult["harnesses"] {
            for (name, profile) in profiles {
                harnesses.append(Harness(
                    name: name,
                    family: profile["family"]?.stringValue,
                    unavailableReason: profile["unavailable"]?.stringValue,
                    models: modelsByHarness[name] ?? []
                ))
            }
        }
        harnesses.sort { lhs, rhs in
            if (lhs.name == defaultHarness) != (rhs.name == defaultHarness) { return lhs.name == defaultHarness }
            if (lhs.unavailableReason == nil) != (rhs.unavailableReason == nil) { return lhs.unavailableReason == nil }
            return lhs.name < rhs.name
        }
        self.init(harnesses: harnesses, defaultHarness: defaultHarness)
    }

    /// The harness named `name`.
    public func harness(named name: String?) -> Harness? {
        guard let name else { return nil }
        return harnesses.first { $0.name == name }
    }
}
