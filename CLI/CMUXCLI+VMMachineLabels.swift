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

    private static let vmResolvedMachineLabelsLock = NSLock()
    private nonisolated(unsafe) static var vmResolvedMachineLabels: [String: String] = [:]

    /// Records that `label` was typed for the machine `id` in this invocation.
    static func rememberVMMachineLabel(_ label: String, for id: String) {
        vmResolvedMachineLabelsLock.lock()
        vmResolvedMachineLabels[id] = label
        vmResolvedMachineLabelsLock.unlock()
    }

    /// How messages name a machine: the label the person typed when this invocation
    /// resolved one to `id`, otherwise `id` itself. A label is also an address every
    /// `cmux vm` verb accepts, so next-step commands built from it still copy and paste.
    static func vmMachineDisplayName(_ id: String) -> String {
        vmResolvedMachineLabelsLock.lock()
        defer { vmResolvedMachineLabelsLock.unlock() }
        return vmResolvedMachineLabels[id] ?? id
    }

    /// `CMUX_DEBUG=1` (or true/yes/on) prints the label-to-id line that is otherwise silent.
    static func vmMachineLabelTraceEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment["CMUX_DEBUG"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Verbs that destroy or stop a machine. A label reaches them only when it is the
    /// machine's own label spelled exactly (no case folding, no slug alias); a near
    /// miss is refused with the machine it probably meant instead of acting on it.
    static let vmDestructiveVerbs: Set<String> = ["rm", "destroy", "delete", "pause"]

    /// Whether a failure says the machine (or something addressed through it) does
    /// not exist. A label reaches the backend as an id it does not know, which comes
    /// back as a 404 from the Cloud API, or from the app as an unknown resource or a
    /// machine it has no connection for. Only the app's own structured answer counts:
    /// a local error (a remote command's exit status, its stderr) is never read as a
    /// lookup failure, so a command that already ran on a machine is never run again.
    static func isVMMachineNotFoundError(_ error: Error) -> Bool {
        guard let error = error as? CLIError, error.isStructuredProtocolResponse || error.v2Code != nil else { return false }
        if let code = error.vmBackendCode?.lowercased(), code.contains("not_found") { return true }
        if let code = error.v2Code?.lowercased(), code == "not_found" || code == "vm_not_found" { return true }
        let message = error.message.lowercased()
        // A provider subrequest can legitimately return a generic HTTP 404
        // while the machine still exists (for example, missing metadata). A
        // bare status code must not trigger a second `vm.list` lookup or rerun
        // the user's command. Only explicit machine/resource wording is safe
        // to interpret as a label lookup miss.
        return ["not found", "unknown machine", "unknown surface", "not connected"]
            .contains { message.contains($0) }
    }

    /// Whether running `cmux vm <verb>` with `arguments` reads standard input, which a
    /// second (label-resolved) attempt could not read again: a `-` operand before `--`
    /// (`vm env set <m> -`, `vm layout apply <m> -`), or `vm layout apply` with no
    /// document source on a non-terminal stdin.
    static func vmArgumentsConsumeStdin(verb: String, arguments: [String], stdinIsTerminal: Bool) -> Bool {
        let end = arguments.firstIndex(of: "--") ?? arguments.count
        let head = Array(arguments[..<end])
        if head.contains("-") { return true }
        guard verb == "layout", head.first == "apply", !stdinIsTerminal else { return false }
        if head.contains("--from-saved") || head.contains(where: { $0.hasPrefix("--from-saved=") }) { return false }
        let valueFlags: Set<String> = ["--workspace", "--name", "--cwd"]
        var operands = 0
        var index = 1
        while index < head.count {
            if valueFlags.contains(head[index]) { index += 2; continue }
            if !head[index].hasPrefix("-") { operands += 1 }
            index += 1
        }
        // `apply <machine> <file>` has its document; `apply <machine>` reads stdin.
        return operands < 2
    }

    /// The label-to-id rewrite of `arguments` against the `vm.list` rows, shared by the
    /// lazy retry and the up-front resolution. Nil when no candidate is a label (an id
    /// came first, or nothing matched); throws for an ambiguous label, and for a near
    /// miss on a destructive verb.
    func vmMachineLabelResolvedArguments(verb: String, arguments: [String], vms: [[String: Any]]) throws -> [String]? {
        let resolver = VMMachineSelectorResolver()
        let strict = Self.vmDestructiveVerbs.contains(verb)
        var firstAmbiguity: (selector: String, matches: [VMMachineSelectorResolver.Match])?
        for candidate in resolver.machineCandidates(in: arguments) {
            switch resolver.resolve(candidate.selector, vms: vms, exactLabelOnly: strict) {
            case .id:
                // The verb already addressed a real machine; its not-found is about
                // something else (a terminal, a workspace, a path).
                return nil
            case .label(let id):
                // Success is silent: the label is the name the person typed, so the
                // verb's own messages name the machine by it (vmMachineDisplayName).
                // CMUX_DEBUG=1 still shows which id the label stood for.
                Self.rememberVMMachineLabel(candidate.selector, for: id)
                if Self.vmMachineLabelTraceEnabled() {
                    cliWriteStderr(String(
                        format: String(localized: "cli.vm.machineLabel.resolved", defaultValue: "[cmux vm] %1$@ is the label of %2$@; using the id."),
                        candidate.selector, id
                    ) + "\n")
                }
                return resolver.replacing(selector: candidate.selector, at: candidate.index, with: id, in: arguments)
            case .ambiguous(let matches):
                if firstAmbiguity == nil { firstAmbiguity = (candidate.selector, matches) }
            case .unknown:
                guard strict, case .label(let id) = resolver.resolve(candidate.selector, vms: vms) else { continue }
                let label = resolver.primaryLabel(of: id, vms: vms) ?? id
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.vm.machineLabel.destructiveNearMiss",
                        defaultValue: "vm %1$@: no machine is named exactly %2$@. Did you mean %3$@ (%4$@)? Type its exact label or its id: cmux vm %1$@ %4$@"
                    ),
                    verb, candidate.selector, label, id
                ))
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

    /// The one place `cmux vm` turns a machine label into its id after a failure.
    /// Resolution is lazy: the verb runs with the argument as typed, and only when it
    /// fails with the app's not-found answer does this read `vm.list` and look the
    /// argument up by label. Ids therefore cost nothing extra, and a label that also
    /// happens to be another machine's id is never reinterpreted. Returns the arguments
    /// to rerun the verb with, or nil when the failure is not about a label (the caller
    /// rethrows). An ambiguous label throws an error listing the matching machines.
    func vmMachineLabelRetryArguments(
        after error: Error,
        verb: String,
        arguments: [String],
        client: SocketClient
    ) throws -> [String]? {
        guard !Self.vmVerbsWithoutMachineArgument.contains(verb),
              Self.isVMMachineNotFoundError(error),
              !VMMachineSelectorResolver().machineCandidates(in: arguments).isEmpty,
              let listResponse = try? client.sendV2(method: "vm.list", responseTimeout: 60) else { return nil }
        let vms = (listResponse["vms"] as? [[String: Any]]) ?? []
        return try vmMachineLabelResolvedArguments(verb: verb, arguments: arguments, vms: vms)
    }

    /// Up-front resolution for a verb that reads stdin (``vmArgumentsConsumeStdin``):
    /// the input can be read only once, so the label becomes the id before the verb
    /// runs. Costs one `vm.list`; an unreadable list leaves the arguments as typed.
    func vmMachineLabelPreResolvedArguments(verb: String, arguments: [String], client: SocketClient) throws -> [String] {
        guard !Self.vmVerbsWithoutMachineArgument.contains(verb),
              !VMMachineSelectorResolver().machineCandidates(in: arguments).isEmpty,
              let listResponse = try? client.sendV2(method: "vm.list", responseTimeout: 60),
              let vms = listResponse["vms"] as? [[String: Any]] else { return arguments }
        return try vmMachineLabelResolvedArguments(verb: verb, arguments: arguments, vms: vms) ?? arguments
    }
}
