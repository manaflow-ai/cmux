import CmuxNextDaemon
import Foundation

/// Resolves an `action.run` target given as a public id, or any unique
/// prefix of one, to the model id the action handlers use
/// (plans/cmux-next/state-ownership.md 4.3). The CLI knows public ids
/// (`win_…`, `ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`, `grp_…`,
/// `tgrp_…`); a workspace's model id is its durable key and a window's its
/// UUID, so those need this mapping. Model ids still resolve.
///
/// Once the topology is loaded, an id that matches nothing is `not_found`
/// and a prefix that matches several objects is `ambiguous`; no handler
/// sees either. Kinds the topology does not list (column, screen group,
/// machine, room) pass through for their handler to check.
enum PublicIDTargetResolver {
    static func resolve(_ ref: ControlTargetRef, in topology: ControlTopology) throws -> ControlTargetRef {
        guard let candidates = self.candidates(for: ControlRouter.normalizedKind(ref.kind), in: topology), topology.isLoaded else {
            return ref
        }
        let exact = candidates.filter { $0.names.contains(ref.id) }
        if let first = exact.first {
            // Fallback ids (`handle:<n>` on daemons without the registry)
            // repeat across sessions: refuse rather than act on the wrong machine.
            guard Set(exact.map(\.sessionID)).count == 1 else { throw ambiguous(ref, exact) }
            return ControlTargetRef(kind: ref.kind, id: first.modelID)
        }
        var seen = Set<String>()
        let prefixed = candidates.filter { $0.names.contains { $0.hasPrefix(ref.id) } && seen.insert(($0.sessionID ?? "") + "/" + $0.modelID).inserted }
        switch prefixed.count {
        case 0:
            throw notFound(ref)
        case 1:
            return ControlTargetRef(kind: ref.kind, id: prefixed[0].modelID)
        default:
            throw ambiguous(ref, prefixed)
        }
    }

    private static func ambiguous(_ ref: ControlTargetRef, _ matches: [Candidate]) -> ControlError {
        ControlError(
            code: "ambiguous",
            message: ControlStrings.format("control.error.targetAmbiguous", "More than one %1$@ starts with %2$@", ref.kind, ref.id),
            data: ["candidates": .array(matches.map { .string($0.names.first ?? $0.modelID) })]
        )
    }

    static func notFound(_ ref: ControlTargetRef) -> ControlError {
        ControlError(code: "not_found", message: ControlStrings.format("control.error.targetNotFound", "No %1$@ matches %2$@", ref.kind, ref.id),
                     data: ["kind": .string(ref.kind), "id": .string(ref.id)])
    }

    /// The public id of the object a resolved (model id) target names.
    static func publicID(of ref: ControlTargetRef, in topology: ControlTopology) -> String {
        candidates(for: ControlRouter.normalizedKind(ref.kind), in: topology)?
            .first { $0.modelID == ref.id }?.names.first ?? ref.id
    }

    struct Candidate {
        var modelID: String
        /// Every id the object answers to, the public one first.
        var names: [String]
        /// The workspace's session (`ControlWorkspaceInfo.sessionID`); nil
        /// for the home session and for kinds that do not carry one.
        var sessionID: String? = nil
    }

    /// Nil for a kind the topology does not list.
    static func candidates(for kind: String, in topology: ControlTopology) -> [Candidate]? {
        let screens = topology.workspaces.flatMap(\.screens)
        let panes = screens.flatMap(\.panes)
        switch kind {
        case "workspace":
            return topology.workspaces.map { Candidate(modelID: $0.id, names: [$0.publicID, $0.id], sessionID: $0.sessionID) }
        case "screen":
            return screens.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "pane":
            return panes.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "tab", "surface", "terminal":
            return panes.flatMap(\.tabs).map { Candidate(modelID: $0.id, names: [$0.id, $0.terminalResourceID, $0.terminalID].compactMap { $0 }) }
        case "window":
            return topology.windows.map { Candidate(modelID: $0.id, names: [$0.publicID, $0.id]) }
        case "workspacegroup":
            return topology.workspaceGroups.map { Candidate(modelID: $0.id, names: [$0.id]) }
        case "tabgroup":
            return panes.flatMap(\.tabGroups).map { Candidate(modelID: $0.id, names: [$0.id]) }
        default:
            return nil
        }
    }

    /// The public id of an object a daemon command created, once the
    /// topology has applied its echo; nil when it is gone again.
    static func publicID(of object: DaemonCreatedObject, in topology: ControlTopology) -> String? {
        let panes = topology.workspaces.flatMap(\.screens).flatMap(\.panes)
        switch object.kind {
        case .workspace:
            return topology.workspaces.first { $0.id == object.id }?.publicID
        case .screen:
            return topology.workspaces.flatMap(\.screens).first { $0.handle == object.id }?.id
        case .pane:
            return panes.first { $0.handle == object.id }?.id
        case .tab:
            return panes.flatMap(\.tabs).first { $0.surface == object.id }?.id
        case .terminal:
            let tab = panes.flatMap(\.tabs).first { $0.terminalID == object.id }
            return tab?.terminalResourceID ?? tab?.terminalID
        case .tabGroup, .workspaceGroup:
            return object.id
        }
    }
}
