import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign

// Leo 2026-11-11: "we wanted the different windows to be accessible through spaces". A window for moved content (Move … to New
// Window, agent fork, tear-off) takes a new space as New Window does (spaces-overhaul rule 3); Open Space in New Window shares (rule 4).
extension WindowManager {
    /// Window `windowID` (normal, no Home, spaces on the home daemon) shows a space another open window shows.
    func sharesItsSpace(_ windowID: String) -> Bool {
        let value = registry.value, local = services.machines.local, members = registry.members(of: windowID)
        guard let state = states[windowID], value.window(windowID)?.isOpen == true, !value.isIncognito(windowID), incognitoSpaces[windowID] == nil,
              local.supports(DaemonCapability.profiles.rawValue), local.store.personal.isLoaded, !members.isEmpty,
              !members.contains(where: { services.workspace(id: $0)?.isAnyHome == true }) else { return false }
        return value.openWindows.contains { $0.id != windowID && states[$0.id]?.profileID == state.profileID }
    }
    /// When it shares one, window `windowID` gets a new space (as New Space) with its workspaces pinned there once reported.
    func giveOwnSpaceIfShared(_ windowID: String) {
        guard sharesItsSpace(windowID), let state = states[windowID], let connection = services.machines.local.connection else { return }
        let machines = services.machines, store = machines.local.store, logger = services.daemon.logger, connected = store.connectionState
        let ids = WindowProfiles.visible(registry.members(of: windowID), profile: state.profileID, machines: machines)
        let space = ProfileID.generate(), name = RoomStrings.defaultName(store.profileIDs.count + 1), browser = store.profile(state.profileID)?.browserProfileID, color = GroupColor.automatic(used: Set(store.profiles.compactMap(\.color))) ?? .grey
        Task {
            do {
                _ = try await connection.createProfile(name: name, id: space, color: color.rawValue, browserProfileID: browser)
                await store.mirrored(profile: space)
                let reported = { ids.compactMap { WindowProfiles.qualified($0, machines: machines) } } // one made for the move may not be yet
                for await done in ObservationStream({ reported().count == ids.count || store.connectionState != connected }) where done { break } // ends on a reconnect
                for workspace in reported() {
                    try await connection.pinWorkspace(session: workspace.session, key: WorkspaceKey(rawValue: workspace.key), to: space)
                }
            } catch {
                logger.error("own space for a new window failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
