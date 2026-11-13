import Foundation

extension CMUXCLI {
    /// Resolve a user-facing machine selector to the canonical provider id.
    ///
    /// Lifecycle endpoints are keyed by id, while the machine list also shows
    /// the mutable display name and stable generated slug. Exact ids always
    /// win. A label or slug is accepted only when it identifies one machine;
    /// ambiguous labels fail closed so an action cannot hit the wrong VM.
    static func resolveVMMachineID(
        selector: String,
        from listResponse: [String: Any]
    ) throws -> String {
        let machines = (listResponse["vms"] as? [[String: Any]])
            ?? (listResponse["machines"] as? [[String: Any]])
            ?? []
        if machines.contains(where: { $0["id"] as? String == selector }) {
            return selector
        }

        var labelMatches = Set<String>()
        for machine in machines {
            guard let id = machine["id"] as? String, !id.isEmpty else { continue }
            if machine["displayName"] as? String == selector || machine["slug"] as? String == selector {
                labelMatches.insert(id)
            }
        }
        if labelMatches.count == 1, let machineID = labelMatches.first {
            return machineID
        }
        if labelMatches.count > 1 {
            let format = String(
                localized: "cli.vm.target.ambiguous",
                defaultValue: "vm: “%1$@” matches multiple machines; use a machine id from cmux vm ls."
            )
            throw CLIError(message: String(format: format, selector))
        }
        return selector
    }

    static func isVMMachineNotFound(_ error: CLIError) -> Bool {
        error.vmBackendCode == "vm_not_found"
            || error.v2Code == "vm_not_found"
    }
}
