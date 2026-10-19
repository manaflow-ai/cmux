import CmuxNextDaemon

/// Aggregates cached observations without inventing absence, accounts or update support.
nonisolated struct AgentCLIInventoryProjection {
    let snapshot: AcpmuxHarnessInventory

    func value(machine: ResourceID) -> AppJSON {
        let classified = snapshot.harnesses.compactMap { row -> (String, AcpmuxHarnessInventory.Harness)? in
            guard let family = row.family, family != .unknown,
                  row.channel != .launcher, row.channel != .missing else { return nil }
            return (family.rawValue, row)
        }
        let groups = Dictionary(grouping: classified, by: { $0.0 })
        let clis = groups.keys.sorted().map { family -> AppJSON in
            let rows = (groups[family] ?? []).map { $0.1 }
            let version = agreed(rows.map(\.version))
            let latest = agreed(rows.map(\.latest)).map { version -> AppJSON in
                let times = rows.map(\.latestCheckedAt)
                let checked = times.allSatisfy { $0 != nil }
                    ? times.compactMap { $0 }.min().flatMap { Double(exactly: $0) } : nil
                return ["version": .string(version), "checked_at": checked.map(AppJSON.number) ?? .null]
            }
            let auth = agreed(rows.map { row -> String? in
                switch row.auth {
                case .signedIn: "signed_in"
                case .signedOut: "missing"
                case .unknown: "unknown"
                }
            }) ?? "unknown"
            let method = agreed(rows.map { row -> String? in
                switch row.channel {
                case .npm: "npm"
                case .bun: "bun"
                case .brew, .brewCask: "brew"
                case .native: "native"
                case .standalone, .launcher, .missing: nil
                }
            })
            return [
                "cli": .string(family), "installed": true,
                "version": version.map(AppJSON.string) ?? .null, "latest": latest ?? .null,
                "install_method": method.map(AppJSON.string) ?? .null,
                "updatable": false, "accounts": .array([]), "auth_status": .string(auth),
            ]
        }
        return ["machine": .string(machine.rawValue), "complete": false, "cached": true, "clis": .array(clis)]
    }

    private func agreed<T: Equatable>(_ values: [T?]) -> T? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
