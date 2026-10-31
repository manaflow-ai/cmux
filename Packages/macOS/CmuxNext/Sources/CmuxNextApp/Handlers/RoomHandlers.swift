import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// Rooms (plans/cmux-next/data-model.md 8; the daemon calls them profiles):
/// create, edit, delete, reorder, switch, and the workspace and group moves.
/// Rooms live on the local daemon (`profiles-v1`); every action is
/// unavailable, with its reason, while that daemon lacks it.
enum RoomHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let local: @MainActor () -> DaemonService? = { context.services.machines.local }
        func bind(_ id: ActionID, _ run: @escaping @MainActor (ActionInvocation) throws -> Void) {
            registry.bind(id, requires: DaemonCapability.profiles.rawValue, daemon: local(), run: { invocation in
                try context.requireRooms()
                try run(invocation)
            })
        }
        bind("space.new") { try create(invocation: $0, context) }
        bind("space.newIncognito") { try create(invocation: $0, context, action: "space.newIncognito", incognito: true) }
        bind("space.newWindow") { invocation in
            let room = try context.room(invocation)
            let windows = context.services.windows
            let windowID = UUID().uuidString.lowercased()
            windows.state(for: windowID).enterProfile(room.id)
            Task { await windows.createWorkspace(into: windowID, newTabPage: invocation.origin == .user) }
        }
        // Open Space in New Window (spaces-overhaul-DESIGN.md rule 4): the new window shows the space and the
        // window it came from keeps it. It takes the space's workspaces no window showing the space lists,
        // else starts with a new workspace there (a workspace is in one window until rule 6's second view).
        bind("space.openInNewWindow") { invocation in
            let room = try context.room(invocation)
            let windows = context.services.windows
            let windowID = UUID().uuidString.lowercased()
            let adoptable = windows.adoptableWorkspaces(in: room.id, for: windowID)
            windows.state(for: windowID).enterProfile(room.id)
            if adoptable.isEmpty {
                Task { await windows.createWorkspace(into: windowID, newTabPage: invocation.origin == .user) }
            } else {
                windows.openWindow(id: windowID, workspaces: adoptable)
            }
        }
        // Move Space to This Window, the inverse: the acting window takes the space's workspaces from
        // every other normal window and shows the space; a window left with none closes.
        bind("space.bringHere") { invocation in
            let room = try context.room(invocation)
            try context.services.windows.bringSpace(room.id, into: context.window(invocation).state)
        }
        bind("space.newWorkspace") { invocation in
            let room = try context.room(invocation)
            let windows = context.services.windows
            let target = windows.targetWindow(preferring: windows.active?.state.id)
            var spawn = WorkspaceSpawn(profile: room.id)
            spawn.opensNewTabPage = invocation.origin == .user
            Task { _ = try? await windows.createWorkspace(spawn, into: target) }
        }
        bind("space.rename") { invocation in
            let room = try context.room(invocation)
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                update(room.id, context) { try await $0.updateProfile($1, name: name) }
            } else {
                context.services.registry.ask("space.rename", invocation, ActionArgumentAsk(argument: "name", initialText: room.name))
            }
        }
        bind("space.setColor") { invocation in
            guard let raw = invocation["color"]?.stringValue, let color = GroupColor(rawValue: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf(GroupColor.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            let room = try context.room(invocation)
            update(room.id, context) { try await $0.updateProfile($1, color: .set(color.rawValue)) }
        }
        for color in GroupColor.allCases {
            bind(ActionID(rawValue: "space.color.\(color.rawValue)")) { invocation in
                let room = try context.room(invocation)
                update(room.id, context) { try await $0.updateProfile($1, color: .set(color.rawValue)) }
            }
        }
        bind("space.clearColor") { invocation in
            let room = try context.room(invocation)
            update(room.id, context) { try await $0.updateProfile($1, color: .clear) }
        }
        bind("space.setIcon") { invocation in
            let room = try context.room(invocation)
            let history = IconHistory.space(context), id = room.id.rawValue
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                try history.change(id, from: room.icon, to: icon, origin: invocation.origin)
            } else if let anchor = context.services.iconPicker.activeWindowAnchor() {
                // Spaces live in the local daemon, which stores their image and SVG icons.
                let assets = IconAssetStore.owner(context.services.machines.local)
                context.services.iconPicker.pick(current: room.icon, target: "space:\(id)", at: anchor, assets: assets) { result in
                    switch result {
                    case .set(let icon): try? history.change(id, from: room.icon, to: icon, origin: .user)
                    case .clear: try? history.change(id, from: room.icon, to: nil, origin: .user)
                    case .cancel: break
                    }
                }
            } else {
                throw ActionFailure.invalidTarget(RoomStrings.iconArgumentRequired)
            }
        }
        bind("space.clearIcon") { invocation in
            let room = try context.room(invocation)
            try IconHistory.space(context).change(room.id.rawValue, from: room.icon, to: nil, origin: invocation.origin)
        }
        bind("space.setDefaults") { invocation in
            let room = try context.room(invocation)
            // Neither argument named (the palette or the space menu with nothing collected): ask
            // for the directory, never clear. Clearing takes both named empty (`cwd=` `env=`).
            // The answer names `cwd` alone, which keeps the space's environment.
            guard RoomDefaultsArguments.names(invocation) else {
                guard invocation.origin == .user,
                      context.services.registry.ask("space.setDefaults", invocation,
                                                    ActionArgumentAsk(argument: "cwd", initialText: room.defaults?.cwd)) else {
                    throw ActionFailure.invalidTarget(RoomStrings.defaultsArgumentRequired)
                }
                return
            }
            let patch = try RoomDefaultsArguments.patch(invocation)
            context.services.roomDefaults.apply(patch, to: room.id, context)
        }
        // Destructive: the palette asks first (RoomConfirmation.clearDefaultsPrompt); automation passes `confirm`.
        bind("space.clearDefaults") { invocation in
            let room = try context.room(invocation)
            context.services.roomDefaults.apply(.clear, to: room.id, context)
        }
        bind("space.delete") { invocation in
            let room = try context.room(invocation)
            guard !room.isDefault else { throw ActionFailure.invalidTarget(RoomStrings.defaultCannotBeDeleted) }
            let moveTo = try context.optionalRoom(invocation["moveTo"])?.id
            let id = room.id, name = room.name, services = context.services
            // Delete Space closes the workspaces only this space shows, in
            // the daemon (SPACE-DELETE-CLOSES-ITS-WORKSPACES); the app
            // releases their remote-terminal tabs first, as for any close.
            if moveTo == nil {
                for workspace in RoomConfirmation.closing(id, context) { WorkspaceClose.willClose?(workspace) }
            }
            // A person's delete gets the Reopen toast; automation does not.
            let toast = moveTo == nil && invocation.origin == .user
            services.machines.local.send("delete-profile") { connection in
                let response = try await connection.deleteProfile(id, moveTo: moveTo)
                guard toast, let closedID = response.closedID else { return }
                await RoomConfirmation.showDeleted(name, closedID: closedID, services: services)
            }
        }
        bind("space.moveLeft") { try move($0, context) { from, _ in from - 1 } }
        bind("space.moveRight") { try move($0, context) { from, _ in from + 1 } }
        bind("space.moveToStart") { try move($0, context) { _, _ in 0 } }
        bind("space.moveToEnd") { try move($0, context) { _, count in count - 1 } }
        bind("space.move") { invocation in
            guard let position = invocation["index"]?.intValue else { throw ActionFailure.invalidTarget(RoomStrings.roomArgumentRequired) }
            try move(invocation, context, allowsStay: true) { _, count in min(max(position - 1, 0), count - 1) }
        }
        bind("space.next") { _ in try step(1, context) }
        bind("space.previous") { _ in try step(-1, context) }
        bind("space.selectByNumber") { invocation in
            guard let number = invocation["index"]?.intValue, let state = context.activeWindow?.state else { return }
            let order = context.services.machines.local.store.profileIDs
            let pick = number >= 9 ? order[order.count - 1] : order[min(number - 1, order.count - 1)]
            context.services.windows.switchProfile(pick, in: state)
        }
        bind("space.switch") { invocation in
            let room = try context.room(invocation)
            let window = try context.window(invocation)
            context.services.windows.switchProfile(room.id, in: window.state)
        }
        RoomMoveHandlers.bind(bind, context: context)
    }

    /// A new space with the next free color and its own first workspace.
    /// One path for the palette, menu, keyboard, CLI, `action.run` and the
    /// strip's New Space button: `enter` (Open Link in New Space) or
    /// `startNewSpace`, which shows the space only when the
    /// run may change the view.
    /// `incognito` (New Incognito Space, spaces-overhaul-DESIGN.md rule 2): named Incognito with the eyeglasses
    /// icon, shown in a new incognito window (`WindowManager.newIncognitoWindow(space:)`), which deletes it when
    /// it closes; it starts on the default browser profile, as an incognito window's pages never use another.
    static func create(invocation: ActionInvocation, _ context: AppActionContext, action: ActionID = "space.new",
                       inNewWindow: Bool = false, incognito: Bool = false,
                       enter: (@MainActor @Sendable (ProfileID, WindowState) -> Void)? = nil) throws {
        let store = context.services.machines.local.store
        let name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? (incognito ? RoomStrings.incognitoName : RoomStrings.defaultName(store.profileIDs.count + 1))
        let used = Set(store.profiles.compactMap(\.color))
        let color = invocation["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
            ?? GroupColor.automatic(used: used) ?? .grey
        let icon = invocation["icon"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? (incognito ? "eyeglasses" : nil)
        let active = context.activeWindow?.state
        // A new room shares the current room's browser profile, so logins
        // keep working (data-model.md 5).
        let browser = incognito ? nil : active.flatMap { store.profile($0.profileID)?.browserProfileID }
        let id = ProfileID.generate()
        let services = context.services
        services.registry.track(Task {
            guard let connection = services.machines.local.connection else { return ActionWorkFailure(action.rawValue, DaemonError.notConnected) }
            do {
                _ = try await connection.createProfile(name: name, id: id, color: color.rawValue, icon: icon, browserProfileID: browser)
                // The reply comes before the home store mirrors the room
                // (`personal-changed`, then a resync). Entering it earlier
                // files the new workspace unpinned (so in `default`) and
                // the window falls back as from a deleted room (cx-d8x5).
                await services.machines.local.store.mirrored(profile: id)
                if incognito {
                    services.windows.newIncognitoWindow(space: id)
                } else if let enter, let active, let state = services.windows.states[active.id] {
                    enter(id, state)
                } else {
                    try await startNewSpace(id, from: inNewWindow ? nil : active?.id, windows: services.windows,
                                            newTabPage: inNewWindow && invocation.origin == .user)
                }
                return nil
            } catch {
                return ActionWorkFailure(action.rawValue, error)
            }
        })
    }

    /// Gives the new, empty space `profile` its first workspace. A run that
    /// may change the view shows the space in window `windowID`
    /// (`switchProfile`, which creates the workspace there). Any other run
    /// (a script, the CLI without `focus`) files the workspace, pinned to
    /// `profile`, into that window without showing it: the window stays in
    /// its space, which never lists the new workspace (cx-f8aw). With no
    /// open window, a new window opens in the space (behind for a run
    /// without view permission).
    private static func startNewSpace(_ profile: ProfileID, from windowID: String?, windows: WindowManager, newTabPage: Bool = false) async throws {
        if let windowID, let state = windows.states[windowID], windows.registry.value.window(windowID)?.isOpen == true {
            if ActionRunScope.viewChangeAllowed() {
                windows.switchProfile(profile, in: state)
            } else {
                _ = try await windows.createWorkspace(WorkspaceSpawn(profile: profile), into: windowID)
            }
            return
        }
        let newWindow = UUID().uuidString.lowercased()
        windows.state(for: newWindow).enterProfile(profile)
        var spawn = WorkspaceSpawn(profile: profile)
        spawn.opensNewTabPage = newTabPage
        _ = try await windows.createWorkspace(spawn, into: newWindow)
    }

    /// New Window (Cmd-Shift-N, the palette, `cmux app new-window`, MCP): a new window on a new space with
    /// its own first workspace (spaces-overhaul-DESIGN.md rule 3), through New Space's one path. Without
    /// spaces on the local daemon (no `profiles-v1`, personal state not loaded) a plain new window.
    static func newWindow(_ invocation: ActionInvocation, _ context: AppActionContext) {
        let services = context.services, local = services.machines.local
        guard local.supports(DaemonCapability.profiles.rawValue), local.store.personal.isLoaded else {
            services.windows.newWindow(holdingKeysFrom: services.windows.active?.window)
            return
        }
        try? create(invocation: invocation, context, action: "newWindow", inNewWindow: true) // create only throws for a bad argument; New Window passes none it reads
    }

    /// Move Left/Right, to Start/End and to Position: `target` maps (position, count) to the new position.
    private static func move(_ invocation: ActionInvocation, _ context: AppActionContext, allowsStay: Bool = false,
                             to target: (Int, Int) -> Int) throws {
        let room = try context.room(invocation), order = context.services.machines.local.store.profileIDs
        guard let from = order.firstIndex(of: room.id),
              let insertion = ProfileBarLogic.moveInsertion(from: from, to: target(from, order.count), count: order.count, allowsStay: allowsStay)
        else { throw ActionFailure.invalidTarget(RoomStrings.roomAtEdge) }
        let id = room.id
        context.services.machines.local.send("move-profile") { try await $0.moveProfile(id, to: insertion) }
    }

    private static func step(_ delta: Int, _ context: AppActionContext) throws {
        guard let state = context.activeWindow?.state else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        guard context.services.windows.stepProfile(by: delta, in: state) else { throw ActionFailure.invalidTarget(RoomStrings.noOtherRoom) }
    }

    /// Sends one room update to the local daemon.
    static func update(_ id: ProfileID, _ context: AppActionContext,
                       _ body: @escaping @Sendable (DaemonConnection, ProfileID) async throws -> Void) {
        context.services.machines.local.send("update-profile") { try await body($0, id) }
    }
}

/// Set and Clear Space Terminal Defaults… for one space, one at a time, each merging its named fields
/// into the defaults the daemon holds when it runs (`list-personal`), never into the app's mirror,
/// which lags a reply: two quick partial runs (`--cwd /a`, then `--env '{"X":"1"}'`) would both read
/// the old mirror, and the second's whole-object write would drop the first's field. One per app
/// (``AppServices/roomDefaults``).
@MainActor
final class RoomDefaultsUpdates {
    /// The newest run per space; the next run waits for it. Each entry ends with its run and is then
    /// removed, unless a newer run replaced it.
    private var tails: [ProfileID: (token: UUID, done: Task<Void, Never>)] = [:]

    /// Ends its stream when the command's body has run, or when the body is dropped unrun (no daemon
    /// connection): the body holds the only reference, so the next run never waits forever.
    private final class Finish: Sendable {
        let signal: AsyncStream<Void>.Continuation
        init(_ signal: AsyncStream<Void>.Continuation) { self.signal = signal }
        nonisolated deinit { signal.finish() }
    }

    /// Whether a run for `id` has not finished yet (its write may not have reached the mirror).
    func inFlight(_ id: ProfileID) -> Bool { tails[id] != nil }

    func apply(_ patch: RoomDefaultsArguments.Patch, to id: ProfileID, _ context: AppActionContext) {
        let previous = tails[id]?.done
        // Nothing is ever yielded; the stream only ends, so one slot is plenty.
        let (finished, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let finish = Finish(signal)
        let token = UUID()
        tails[id] = (token, Task { @MainActor [weak self] in
            for await _ in finished {}
            if self?.tails[id]?.token == token { self?.tails[id] = nil }
        })
        context.services.machines.local.send("update-profile") { connection in
            defer { finish.signal.finish() }
            await previous?.value
            let current = try await connection.listPersonal().profiles.first(where: { $0.id == id })?.defaults
            let defaults = patch.applied(to: current)
            try await connection.updateProfile(id, defaults: defaults.isEmpty ? .clear : .set(defaults))
        }
    }
}
