import CmuxNextDaemon
import CmuxNextLayout

// A window is a view of a space (Lawrence 2026-11-15: "if i make a new window, it makes it as a new space, so
// technically it's accessible from my original window. then if i switch to that space from original window, and view a
// terminal, that terminal must be shared"; plans/cmux-next/spaces-overhaul-DESIGN.md rule 6). A window on space R lists
// every workspace of R: the ones it owns, and as guests (`WindowRegistry.Window.guests`) the ones another open window
// owns. The guests follow from the owners, each window's space and the spaces' rules alone, so this is their one writer:
// every membership transition and every space a window enters sets them again. Nothing else adds or drops a guest.
extension WindowManager {
    /// Whether window `id` takes part in shared spaces: open, normal (incognito content never shows in another window,
    /// spaces-overhaul rule 2), with a state.
    private func sharesSpaces(_ id: String, in registry: WindowRegistry) -> Bool {
        registry.window(id)?.isOpen == true && !registry.isIncognito(id) && incognitoSpaces[id] == nil && states[id] != nil
    }

    /// The workspaces of space `profile` that window `id` lists as guests while it shows `profile`: those another open
    /// normal window owns, in those windows' order. The default space is a space like every other: two windows on it list
    /// each other's workspaces, also when the person made no space (a space is the same from every window). Empty until
    /// the home session's spaces load. A Home is each window's own; a workspace no session reports yet has no space to be
    /// shared in. `cache` holds one owner window's answer per space for one pass over the windows (`shareSpaces`).
    func sharedWorkspaces(in profile: ProfileID, for id: String, registry: WindowRegistry, cache: inout [String: [String]]) -> [String] {
        let machines = services.machines
        // A window not opened yet (`openView`) asks for what it would list.
        guard WindowProfiles.membership(machines) != nil, registry.window(id) == nil || sharesSpaces(id, in: registry) else { return [] }
        var shared: [String] = []
        for other in registry.windows where other.id != id && sharesSpaces(other.id, in: registry) {
            let key = other.id + "\u{1F}" + profile.rawValue
            if let known = cache[key] { shared += known; continue }
            let owned = WindowProfiles.visible(other.ownedIDs, profile: profile, machines: machines).filter { workspace in
                WindowProfiles.qualified(workspace, machines: machines) != nil && services.workspace(id: workspace)?.isAnyHome != true
            }
            cache[key] = owned
            shared += owned
        }
        return shared
    }

    func sharedWorkspaces(in profile: ProfileID, for id: String, registry: WindowRegistry) -> [String] {
        var cache: [String: [String]] = [:]
        return sharedWorkspaces(in: profile, for: id, registry: registry, cache: &cache)
    }

    /// Sets every window's guests for the space it shows now (one window: no guests, and nothing is read; a window a Move Space took from: none, `gatherSources`).
    func shareSpaces(_ registry: inout WindowRegistry) {
        let sharing = registry.windows.filter { sharesSpaces($0.id, in: registry) }
        var cache: [String: [String]] = [:] // each owner window's list is filtered once per space, not once per viewer
        for window in registry.windows {
            let guests = sharing.count > 1 && !self.registry.gatherSources.contains(window.id) ? states[window.id].map { sharedWorkspaces(in: $0.profileID, for: window.id, registry: registry, cache: &cache) } ?? [] : []
            guard !guests.isEmpty || !window.guests.isEmpty else { continue }
            registry.setGuests(guests, of: window.id)
        }
    }

    /// Opens new window `id` as one more view of space `profile`, whose workspaces other windows own (Open Space in New
    /// Window): it lists them all and owns none. Nil when the space has no such workspace (the caller makes one).
    @discardableResult
    func openView(id: String, of profile: ProfileID) -> WindowController? {
        let shared = sharedWorkspaces(in: profile, for: id, registry: registry.value)
        guard !shared.isEmpty else { return nil }
        let state = state(for: id)
        if state.profileID != profile { state.enterProfile(profile) }
        transition(select: [id: shared], gesture: true) { registry in
            registry.openView(id: id, guests: shared)
            return WindowRegistry.Changes()
        }
        return controller(for: id)
    }

    /// The window an action on `workspaceID` acts in: the one the person acts in when it lists the workspace (its own or
    /// a guest), else the workspace's owner. Two windows can list one workspace, so "its window" alone names two.
    func actingWindow(for workspaceID: String) -> String? {
        if let acting = active?.state.id, registry.value.lists(workspaceID, in: acting) { return acting }
        return registry.value.owner(of: workspaceID)
    }

    /// The controllers, the one the person acts in first: a pane or tab that two windows show resolves to theirs.
    var controllersActingFirst: [WindowController] {
        guard controllers.count > 1, let acting = active else { return controllers }
        return [acting] + controllers.filter { $0 !== acting }
    }

    /// A window entered a space (`WindowState.onProfileChange`: a space switch, a selection of another space's
    /// workspace, a selection repair): the guests are set again in this turn, so the window lists the space's shared
    /// workspaces before anything reads its list. Only lists change: no window opens or closes (`setGuests`), and the
    /// caller that moved the window to the space selects what it shows there.
    func spaceDidChange() {
        registry.apply { registry in
            shareSpaces(&registry)
            return WindowRegistry.Changes()
        }
    }
}
