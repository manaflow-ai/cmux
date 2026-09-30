import Foundation

/// Resolves an `action.run` target given as a public id, or any unique
/// prefix of one, to the model id the action handlers use. The CLI only
/// knows public ids (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`) and
/// the app's window ids (plans/cmux-next/cli.md, C7); a workspace's model
/// id is its durable key, so `ws_…` needs this mapping. An id that matches
/// nothing passes through unchanged for the handler to reject.
enum PublicIDTargetResolver {
    static func resolve(_ ref: ControlTargetRef, in topology: ControlTopology) throws -> ControlTargetRef {
        let candidates = self.candidates(for: ControlRouter.normalizedKind(ref.kind), in: topology)
        guard !candidates.isEmpty else { return ref }
        if let exact = candidates.first(where: { $0.names.contains(ref.id) }) {
            return ControlTargetRef(kind: ref.kind, id: exact.modelID)
        }
        var seen = Set<String>()
        let prefixed = candidates.filter { $0.names.contains { $0.hasPrefix(ref.id) } && seen.insert($0.modelID).inserted }
        switch prefixed.count {
        case 0:
            return ref
        case 1:
            return ControlTargetRef(kind: ref.kind, id: prefixed[0].modelID)
        default:
            throw ControlError(
                code: "ambiguous",
                message: ControlStrings.format("control.error.targetAmbiguous", "More than one %1$@ starts with %2$@", ref.kind, ref.id),
                data: ["candidates": .array(prefixed.map { .string($0.names.first ?? $0.modelID) })]
            )
        }
    }

    struct Candidate {
        var modelID: String
        /// Every id the object answers to, the public one first.
        var names: [String]
    }

    static func candidates(for kind: String, in topology: ControlTopology) -> [Candidate] {
        let screens = topology.workspaces.flatMap(\.screens)
        let panes = screens.flatMap(\.panes)
        switch kind {
        case "workspace":
            return topology.workspaces.map { Candidate(modelID: $0.id, names: [$0.resourceID, $0.id].compactMap { $0 }) }
        case "screen":
            return screens.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "pane":
            return panes.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "tab", "surface", "terminal":
            return panes.flatMap(\.tabs).map { Candidate(modelID: $0.id, names: [$0.id, $0.terminalID].compactMap { $0 }) }
        case "window":
            return topology.windows.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "workspacegroup":
            return topology.workspaceGroups.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "tabgroup":
            return panes.flatMap(\.tabGroups).map { Candidate(modelID: $0.id, names: [$0.id]) }
        default:
            return []
        }
    }
}
