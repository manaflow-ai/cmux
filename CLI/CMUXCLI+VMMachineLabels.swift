import Foundation

// MARK: - Machine labels as `cmux vm` addresses

extension CMUXCLI {
    /// Verbs whose arguments never name an existing machine (they list, create,
    /// restore from a snapshot id, or act on local state), so a not-found failure
    /// there is never a label to resolve. Everything else may take a machine.
    private static let vmVerbsWithoutMachineArgument: Set<String> = [
        "ls", "list", "new", "create", "domains", "prompt", "skill", "base", "restore",
        "route", "secrets", "clone", "repo", "compatible-tags", "set-font", "guide",
    ]

    /// Whether a failure says the machine (or something addressed through it) does
    /// not exist. A label reaches the backend as an id it does not know, which comes
    /// back as a 404 from the Cloud API, or from the app as an unknown resource or a
    /// machine it has no connection for. Only a label that resolves acts on this, so a
    /// broad match costs at most one `vm.list` read on an already-failing command.
    static func isVMMachineNotFoundError(_ error: Error) -> Bool {
        guard let error = error as? CLIError else { return false }
        if error.vmBackendHTTPStatus == 404 { return true }
        if let code = error.vmBackendCode?.lowercased(), code.contains("not_found") { return true }
        if let code = error.v2Code?.lowercased(), code == "not_found" || code == "vm_not_found" { return true }
        let message = error.message.lowercased()
        return ["not found", "unknown machine", "unknown surface", "not connected", "404"]
            .contains { message.contains($0) }
    }

    /// The one place `cmux vm` turns a machine label into its id. Resolution is lazy:
    /// the verb runs with the argument as typed, and only when it fails with a
    /// not-found error does this read `vm.list` and look the argument up by label.
    /// Ids therefore cost nothing extra, and a label that also happens to be another
    /// machine's id is never reinterpreted. Returns the arguments to rerun the verb
    /// with, or nil when the failure is not about a label (the caller rethrows).
    /// An ambiguous label throws an error listing the matching machines.
    func vmMachineLabelRetryArguments(
        after error: Error,
        verb: String,
        arguments: [String],
        client: SocketClient
    ) throws -> [String]? {
        guard !Self.vmVerbsWithoutMachineArgument.contains(verb),
              Self.isVMMachineNotFoundError(error) else { return nil }
        let resolver = VMMachineSelectorResolver()
        let candidates = resolver.machineCandidates(in: arguments)
        guard !candidates.isEmpty,
              let listResponse = try? client.sendV2(method: "vm.list", responseTimeout: 60) else { return nil }
        let vms = (listResponse["vms"] as? [[String: Any]]) ?? []
        var firstAmbiguity: (selector: String, matches: [VMMachineSelectorResolver.Match])?
        for candidate in candidates {
            switch resolver.resolve(candidate.selector, vms: vms) {
            case .id:
                // The verb already addressed a real machine; its not-found is about
                // something else (a terminal, a workspace, a path).
                return nil
            case .label(let id):
                cliWriteStderr(String(
                    format: String(localized: "cli.vm.machineLabel.resolved", defaultValue: "[cmux vm] %1$@ is the label of %2$@; using the id."),
                    candidate.selector, id
                ) + "\n")
                return resolver.replacing(selector: candidate.selector, at: candidate.index, with: id, in: arguments)
            case .ambiguous(let matches):
                if firstAmbiguity == nil { firstAmbiguity = (candidate.selector, matches) }
            case .unknown:
                continue
            }
        }
        if let firstAmbiguity {
            let list = firstAmbiguity.matches.map { "  \($0.id)  \($0.label)" }.joined(separator: "\n")
            throw CLIError(message: String(
                format: String(localized: "cli.vm.machineLabel.ambiguous", defaultValue: "%1$@ is the label of more than one machine; use an id:\n%2$@"),
                firstAmbiguity.selector, list
            ))
        }
        return nil
    }
}
