import Foundation

/// Pure diff that turns the shared view connection's published workspaces into the
/// create / update / remove actions the controller applies to its per-session
/// mirrors, when a host's sessions are multiplexed over one `tmux -CC` stream.
///
/// Keyed by session name — the GA workspace identity — so a multiplexed host uses
/// the exact same one-workspace-per-session model as a dedicated-connection host.
/// A session RENAME is detected by the rename-stable `$N` session id: an incoming
/// workspace whose id matches an existing mirror under a different name is a
/// `rename` (re-key the live mirror, matching GA's `%session-renamed` re-key),
/// never a remove-old + create-new that would destroy the workspace's scrollback,
/// panes, and selection.
///
/// Pure (no tmux, no I/O) so the reconcile policy is deterministic and unit-testable;
/// the controller performs the resulting side effects (channel + workspace + mirror).
enum RemoteTmuxMultiplexReconciler {
    /// One session's scoped window set, ready to drive a channel + mirror. Window ids
    /// are the numeric form the control connection keys `windowsByID` on, ORDERED by
    /// the home session's window indexes (the model's order) — this order IS the
    /// mirror's tab order, so collapsing it to a set would replay the hidden view's
    /// arbitrary link order instead. `sessionId` is the session's stable numeric tmux
    /// id (`$N` → `N`), nil when the snapshot carried none.
    struct SessionView: Equatable {
        let sessionName: String
        let sessionId: Int?
        let windowIds: [Int]
    }

    /// One live mirror already registered for a host. `sessionId` is nil until tmux
    /// has published a `$N`, but `windowIds` are still identity evidence: a
    /// pre-id mirror whose windows reappear under a different id-bearing name is a
    /// rename, not a same-name update onto an unrelated new session.
    struct ExistingMirror: Equatable {
        let sessionName: String
        let sessionId: Int?
        let windowIds: [Int]
    }

    /// A session identity recorded by controller intents. The name is only a fallback
    /// target until tmux exposes the stable `$id`; once the id is known it is primary.
    struct SessionRef: Equatable, Hashable {
        var name: String
        var id: Int?
    }

    /// A pending "select the workspace once it surfaces" intent from New Workspace.
    struct PendingSelect: Equatable {
        var sessionName: String
        var originatingTabId: UUID
    }

    /// User intents that outlive one reconcile: sessions closed with a kill in flight,
    /// sessions deliberately detached locally, and the one session to select on create.
    struct Intents: Equatable {
        var pendingKills: [SessionRef] = []
        var detached: [SessionRef] = []
        var pendingSelect: PendingSelect?

        var isEmpty: Bool {
            pendingKills.isEmpty && detached.isEmpty && pendingSelect == nil
        }
    }

    /// A live mirror whose session was renamed remotely: same stable id, new name.
    struct Rename: Equatable {
        let oldName: String
        let view: SessionView
    }

    /// A new mirror to create. Selection is resolved by name in the pure planner; the
    /// controller still checks the live originating tab before actually selecting.
    struct Create: Equatable {
        let view: SessionView
        let select: Bool
    }

    struct Plan: Equatable {
        /// Sessions with no mirror yet — create a channel + workspace + mirror.
        var create: [Create]
        /// Sessions that already have a mirror — rescope its channel's window set.
        var update: [SessionView]
        /// Existing mirrors to re-key under the session's new name (rename-session).
        var rename: [Rename]
        /// Session names whose mirror should be torn down (session gone from the host).
        var remove: [String]
        /// Pending kills that still describe a present session and must be retried.
        var killRetries: [SessionRef]
    }

    /// Parses a tmux `@N` window id to its numeric form (the id space the control
    /// connection keys `windowsByID`/`windowOrder` on). Returns nil for a malformed id.
    static func numericWindowId(_ id: String) -> Int? {
        Int(id.hasPrefix("@") ? id.dropFirst() : Substring(id))
    }

    /// Projects a published workspace to a numeric-id `SessionView` (dropping any
    /// malformed window id rather than failing the whole session). Preserves the
    /// model's window ORDER — the workspace's tab order — with a numeric parse, so
    /// `@10` never sorts before `@2` the way the raw strings would.
    static func sessionView(_ ws: RemoteTmuxLinkedWorkspaceModel.Workspace) -> SessionView {
        SessionView(
            sessionName: ws.sessionName,
            sessionId: ws.sessionId,
            windowIds: ws.windowIds.compactMap(numericWindowId)
        )
    }

    /// Diffs the published `workspaces` against live mirrors and pending user intents,
    /// in stable order (create/update/rename follow `workspaces`; remove is sorted).
    ///
    /// Identity is id-primary whenever both sides know a `$N`: a same-id different-name
    /// pair is a rename even when the old name is still present in the snapshot (the
    /// two-session swap case). For mirrors that predate id publication, stable window
    /// ids are the next fallback; name matching is only used when no id/window evidence
    /// contradicts it. The same id-primary rule prunes pending-kill/detach intents, so
    /// a new same-name/different-id session is treated as innocent new work instead of
    /// being suppressed by a stale exclusion.
    static func plan(
        workspaces: [RemoteTmuxLinkedWorkspaceModel.Workspace],
        existingMirrors: [ExistingMirror],
        intents: Intents
    ) -> (plan: Plan, survivingIntents: Intents) {
        let views = workspaces.map(sessionView(_:))
        let desiredNames = Set(views.map(\.sessionName))
        let presentById = Dictionary(
            views.compactMap { view -> (Int, SessionView)? in
                guard let id = view.sessionId else { return nil }
                return (id, view)
            },
            uniquingKeysWith: { _, last in last }
        )

        let survivingKills = survivingSessionRefs(
            intents.pendingKills,
            presentNames: desiredNames,
            presentById: presentById
        )
        let survivingDetached = survivingSessionRefs(
            intents.detached,
            presentNames: desiredNames,
            presentById: presentById
        )
        let pendingSelect = intents.pendingSelect.flatMap { pending -> PendingSelect? in
            desiredNames.contains(pending.sessionName) ? nil : pending
        }

        let existingByName = Dictionary(
            existingMirrors.map { ($0.sessionName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingNameById = Dictionary(
            existingMirrors.compactMap { entry -> (Int, String)? in
                guard let id = entry.sessionId else { return nil }
                return (id, entry.sessionName)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let idMatchByViewName = Dictionary(
            views.compactMap { view -> (String, String)? in
                guard let id = view.sessionId, let oldName = existingNameById[id] else {
                    return nil
                }
                return (view.sessionName, oldName)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let windowMatchByViewName = nilIdWindowMatches(
            views: views,
            existingMirrors: existingMirrors,
            reservedExistingNames: Set(idMatchByViewName.values),
            idMatchedViewNames: Set(idMatchByViewName.keys)
        )
        let reservedExistingNames = Set(idMatchByViewName.values)
            .union(windowMatchByViewName.values)

        var create: [Create] = []
        var update: [SessionView] = []
        var rename: [Rename] = []
        var consumedExistingNames: Set<String> = []
        func consume(_ oldName: String, for view: SessionView) {
            consumedExistingNames.insert(oldName)
            if oldName == view.sessionName {
                update.append(view)
            } else {
                rename.append(Rename(oldName: oldName, view: view))
            }
        }
        for view in views {
            if let oldName = idMatchByViewName[view.sessionName] {
                consume(oldName, for: view)
            } else if let oldName = windowMatchByViewName[view.sessionName] {
                consume(oldName, for: view)
            } else if let existing = existingByName[view.sessionName],
                      !reservedExistingNames.contains(view.sessionName),
                      view.sessionId == nil || existing.sessionId == nil {
                consumedExistingNames.insert(view.sessionName)
                update.append(view)
            } else if !isSuppressed(view, by: survivingKills)
                        && !isSuppressed(view, by: survivingDetached) {
                create.append(Create(
                    view: view,
                    select: intents.pendingSelect?.sessionName == view.sessionName
                ))
            }
        }
        let remove = existingByName.keys
            .filter { !consumedExistingNames.contains($0) }
            .sorted()
        return (
            Plan(
                create: create,
                update: update,
                rename: rename,
                remove: remove,
                killRetries: survivingKills
            ),
            Intents(
                pendingKills: survivingKills,
                detached: survivingDetached,
                pendingSelect: pendingSelect
            )
        )
    }

    private static func nilIdWindowMatches(
        views: [SessionView],
        existingMirrors: [ExistingMirror],
        reservedExistingNames: Set<String>,
        idMatchedViewNames: Set<String>
    ) -> [String: String] {
        let candidates = existingMirrors.filter {
            $0.sessionId == nil
                && !reservedExistingNames.contains($0.sessionName)
                && !$0.windowIds.isEmpty
        }
        guard !candidates.isEmpty else { return [:] }

        var candidateByViewName: [String: String] = [:]
        var viewNamesByCandidate: [String: [String]] = [:]
        for view in views {
            guard view.sessionId != nil,
                  !idMatchedViewNames.contains(view.sessionName),
                  !view.windowIds.isEmpty else {
                continue
            }
            let viewWindows = Set(view.windowIds)
            let matches = candidates.filter { candidate in
                !viewWindows.isDisjoint(with: candidate.windowIds)
            }
            guard matches.count == 1, let match = matches.first else { continue }
            candidateByViewName[view.sessionName] = match.sessionName
            viewNamesByCandidate[match.sessionName, default: []].append(view.sessionName)
        }

        return candidateByViewName.filter { _, oldName in
            viewNamesByCandidate[oldName]?.count == 1
        }
    }

    private static func survivingSessionRefs(
        _ refs: [SessionRef],
        presentNames: Set<String>,
        presentById: [Int: SessionView]
    ) -> [SessionRef] {
        var result: [SessionRef] = []
        var seen: Set<SessionRef> = []
        for ref in refs {
            let next: SessionRef?
            if let id = ref.id {
                next = presentById[id].map { SessionRef(name: $0.sessionName, id: id) }
            } else {
                next = presentNames.contains(ref.name) ? ref : nil
            }
            guard let next, seen.insert(next).inserted else { continue }
            result.append(next)
        }
        return result
    }

    private static func isSuppressed(_ view: SessionView, by refs: [SessionRef]) -> Bool {
        refs.contains { ref in
            guard ref.name == view.sessionName else { return false }
            return ref.id == nil || ref.id == view.sessionId
        }
    }

}
