import Foundation

/// Resolves a `cmux vm` machine argument against the `vm.list` rows. A machine is
/// addressed by its id (the NAME column of `vm ls`); its label (`vm rename`, or the
/// slug the backend gave it) is what people read in that list and naturally type.
/// Ids always win, so a label can never shadow another machine's id.
struct VMMachineSelectorResolver: Sendable {
    /// One machine a label matched, for the ambiguity error.
    struct Match: Equatable, Sendable {
        let id: String
        let label: String
    }

    enum Resolution: Equatable, Sendable {
        /// The selector is already a machine id.
        case id(String)
        /// The selector is the label of exactly one machine.
        case label(id: String)
        /// Several machines carry this label; the caller must pick an id.
        case ambiguous([Match])
        /// No machine has this id or label.
        case unknown
    }

    /// `exactLabelOnly` (destructive verbs) accepts only the machine's own label as
    /// `vm ls` shows it, spelled exactly: no case folding and no slug alias.
    func resolve(_ rawSelector: String, vms: [[String: Any]], exactLabelOnly: Bool = false) -> Resolution {
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { return .unknown }
        let rows = vms.compactMap { vm -> (id: String, labels: [String])? in
            guard let id = vm["id"] as? String, !id.isEmpty else { return nil }
            let labels = Self.labels(of: vm)
            return (id: id, labels: exactLabelOnly ? Array(labels.prefix(1)) : labels)
        }
        if rows.contains(where: { $0.id == selector }) { return .id(selector) }
        // Exact spelling first; a case-insensitive match only when nothing matches exactly.
        var matches = rows.filter { $0.labels.contains(selector) }
        if matches.isEmpty, !exactLabelOnly {
            let folded = selector.lowercased()
            matches = rows.filter { row in row.labels.contains { $0.lowercased() == folded } }
        }
        switch matches.count {
        case 0: return .unknown
        case 1: return .label(id: matches[0].id)
        default:
            return .ambiguous(matches.map { Match(id: $0.id, label: $0.labels.first ?? $0.id) })
        }
    }

    /// A machine's labels, the one `vm ls` shows first (its display name, else its slug).
    private static func labels(of vm: [String: Any]) -> [String] {
        [vm["displayName"], vm["slug"]]
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
    }

    /// The label `vm ls` shows for the machine `id`, for messages.
    func primaryLabel(of id: String, vms: [[String: Any]]) -> String? {
        vms.first { ($0["id"] as? String) == id }.flatMap { Self.labels(of: $0).first }
    }

    /// The tokens of a `cmux vm <verb>` argument list that may name a machine, in the
    /// order they should be tried: a `--machine` value first, then every positional
    /// token before `--` (whole, and the machine part of `<m>/<ws>/…` or `<m>:desktop`).
    /// Each candidate carries the argument index and the prefix to replace.
    func machineCandidates(in arguments: [String]) -> [(index: Int, selector: String)] {
        let end = arguments.firstIndex(of: "--") ?? arguments.count
        var machineFlagValues: [(index: Int, selector: String)] = []
        var positional: [(index: Int, selector: String)] = []
        var index = 0
        while index < end {
            let token = arguments[index]
            if token == "--machine", index + 1 < end {
                machineFlagValues.append((index: index + 1, selector: arguments[index + 1]))
                index += 2
                continue
            }
            if Self.nonMachineValueOptions.contains(token) {
                index += 2
                continue
            }
            if !token.hasPrefix("-"), !token.isEmpty {
                positional.append((index: index, selector: token))
                if let separator = token.firstIndex(where: { $0 == "/" || $0 == ":" }), separator != token.startIndex {
                    positional.append((index: index, selector: String(token[..<separator])))
                }
            }
            index += 1
        }
        return machineFlagValues + positional
    }

    /// Options whose value is never a machine, so `--name codex` or `--agent codex`
    /// cannot be mistaken for a machine labeled "codex".
    private static let nonMachineValueOptions: Set<String> = [
        "--agent", "--name", "--cwd", "--remote-cwd", "--size", "--timeout", "--remote-workspace",
        "--workspace", "--window", "--keys", "--pattern", "--after", "--max-bytes", "--cpu",
        "--memory", "--disk", "--provider", "--from-file", "--from-saved", "--branch",
        "--pull", "--dir", "--interval", "--exclude", "--mode", "--reason", "--port", "--command", "--layout",
    ]

    /// `arguments` with the token at `index` (or its machine prefix) replaced by `id`.
    func replacing(selector: String, at index: Int, with id: String, in arguments: [String]) -> [String] {
        var result = arguments
        let token = result[index]
        if token == selector {
            result[index] = id
        } else if token.hasPrefix(selector) {
            result[index] = id + token.dropFirst(selector.count)
        }
        return result
    }
}
