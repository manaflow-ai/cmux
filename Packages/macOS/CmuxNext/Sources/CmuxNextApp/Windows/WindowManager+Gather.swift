import CmuxNextActions
import CmuxNextDaemon
import Foundation

// Folding windows together (Leo 2026-10-29: "having windows be switchable in this way"): the
// inverse of Open Space in New Window. A window takes one space out of the other windows (Move
// Space to This Window), or takes every other window's workspaces (Merge All Windows). Each is
// one registry transition: workspaces change owner and keep running (nothing restarts), and a
// window left with none closes (`WindowRegistry.move`). Incognito content never moves
// (spaces-overhaul-DESIGN.md rule 2).
extension WindowManager {
    /// Move Space to This Window: every workspace of `profile` another normal window holds
    /// (open or closed) moves into `state`'s window, which then shows `profile` with the
    /// workspace the space last showed. With none elsewhere it is a plain space switch.
    /// Refused for an incognito space and in an incognito window.
    func bringSpace(_ profile: ProfileID, into state: WindowState) throws {
        let value = registry.value
        if value.isIncognito(state.id) || incognitoSpaces[state.id] != nil || incognitoSpaces.values.contains(profile) {
            throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch)
        }
        let machines = services.machines
        let sources = value.windows.filter { $0.id != state.id && !value.isIncognito($0.id) }
        let moving = sources.flatMap { WindowProfiles.visible($0.workspaceIDs, profile: profile, machines: machines) }
        guard !moving.isEmpty else { return switchProfile(profile, in: state) }
        // A window already on the space keeps its selection; else the space's last shown workspace.
        var preferred: [String: [String]] = [:]
        if state.profileID != profile {
            let candidates = Set(moving + WindowProfiles.visible(value.window(state.id)?.workspaceIDs ?? [], profile: profile, machines: machines))
            preferred[state.id] = lastShown(in: profile, recency: value.recency, here: state).filter(candidates.contains)
            state.enterProfile(profile)
        }
        transition(select: preferred) { $0.move(moving, to: state.id) }
        recordSaver.stateDidChange(state)
    }

    /// Merge All Windows: every other open normal window's workspaces move into `state`'s
    /// window, each keeping its space, and those windows close. `state`'s window keeps its
    /// space and selection, and takes the others' last shown workspace per space for the
    /// spaces it never showed. Incognito windows stay as they are; refused in one.
    func mergeWindows(into state: WindowState) throws {
        let value = registry.value
        guard !value.isIncognito(state.id), incognitoSpaces[state.id] == nil else {
            throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch)
        }
        let sources = value.openWindows.filter { $0.id != state.id && !value.isIncognito($0.id) }
        let moving = sources.flatMap(\.workspaceIDs)
        guard !moving.isEmpty else { return }
        // Front first, so the most recent window's pick wins for a space.
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for source in sources.sorted(by: { order[$0.id, default: .max] < order[$1.id, default: .max] }) {
            guard let other = states[source.id] else { continue }
            var shown = other.profileWorkspaces
            if let workspaceID = other.workspaceID { shown[other.profileID] = workspaceID }
            for (profile, workspaceID) in shown where profile != state.profileID && state.profileWorkspaces[profile] == nil {
                state.profileWorkspaces[profile] = workspaceID
            }
        }
        transition { $0.move(moving, to: state.id) }
        recordSaver.stateDidChange(state)
    }

    /// The workspaces `profile` last showed, best first: the one each window showing it shows
    /// (front window first), then each window's remembered one there (this window first).
    private func lastShown(in profile: ProfileID, recency: [String], here state: WindowState) -> [String] {
        let others = recency.filter { $0 != state.id }.compactMap { states[$0] }
        let showing = others.filter { $0.profileID == profile }.compactMap(\.workspaceID)
        let remembered = ([state] + others).compactMap { $0.profileWorkspaces[profile] }
        return showing + remembered
    }
}
