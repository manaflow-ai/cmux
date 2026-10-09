import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign

/// Rooms (plans/cmux-next/data-model.md 8; the daemon calls them profiles):
/// create, edit, delete, reorder, switch, and the workspace and group moves.
/// Rooms live on the local daemon (`profiles-v1`); every action is
/// unavailable, with its reason, while that daemon lacks it.
enum RoomHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let local: @MainActor () -> DaemonService? = { context.services.machines.local }
        func bind(_ id: ActionID, _ run: @escaping @MainActor (ActionInvocation) throws -> Void) {
            registry.bind(id, requires: DaemonCapabilities.shared.profiles, daemon: local(), run: { invocation in
                try context.requireRooms()
                try run(invocation)
            })
        }
        bind("space.new") { try create(invocation: $0, context) }
        bind("space.newWindow") { invocation in
            let room = try context.room(invocation)
            let windows = context.services.windows
            let windowID = UUID().uuidString.lowercased()
            windows.state(for: windowID).enterProfile(room.id)
            Task { await windows.createWorkspace(into: windowID, newTabPage: invocation.origin == .user) }
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
            } else if let window = context.activeWindow?.window {
                RenamePrompt.run(title: RoomStrings.renameTitle, initial: room.name, in: window) { name in
                    update(room.id, context) { try await $0.updateProfile($1, name: name) }
                }
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
                context.services.iconPicker.pick(current: room.icon, target: "space:\(id)", at: anchor) { result in
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
            let defaults = try RoomDefaultsArguments.parse(invocation)
            update(room.id, context) { try await $0.updateProfile($1, defaults: defaults.isEmpty ? .clear : .set(defaults)) }
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
        bind("space.moveLeft") { try move(invocation: $0, by: -1, context) }
        bind("space.moveRight") { try move(invocation: $0, by: 1, context) }
        bind("space.move") { invocation in
            let room = try context.room(invocation)
            guard let position = invocation["index"]?.intValue else { throw ActionFailure.invalidTarget(RoomStrings.roomArgumentRequired) }
            let order = context.services.machines.local.store.profileIDs
            let from = order.firstIndex(of: room.id) ?? 0
            let target = min(max(position - 1, 0), order.count - 1)
            // Insertion index: past the removed slot when moving right.
            let insertion = target > from ? target + 1 : target
            let id = room.id
            context.services.machines.local.send("move-profile") { try await $0.moveProfile(id, to: insertion) }
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

    /// A new space with the next free color; the active window enters it
    /// (`enter`, else a switch that opens a new terminal workspace there).
    static func create(invocation: ActionInvocation, _ context: AppActionContext, action: ActionID = "space.new",
                       enter: (@MainActor @Sendable (ProfileID, WindowState) -> Void)? = nil) throws {
        let store = context.services.machines.local.store
        let name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? RoomStrings.defaultName(store.profileIDs.count + 1)
        let used = Set(store.profiles.compactMap(\.color))
        let color = invocation["color"]?.stringValue.flatMap(GroupColor.init(rawValue:))
            ?? GroupColor.automatic(used: used) ?? .grey
        let icon = invocation["icon"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let active = context.activeWindow?.state
        // A new room shares the current room's browser profile, so logins
        // keep working (data-model.md 5).
        let browser = active.flatMap { store.profile($0.profileID)?.browserProfileID }
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
                if let active, let state = services.windows.states[active.id] {
                    if let enter { enter(id, state) } else { services.windows.switchProfile(id, in: state) }
                }
                return nil
            } catch {
                return ActionWorkFailure(action.rawValue, error)
            }
        })
    }

    private static func move(invocation: ActionInvocation, by delta: Int, _ context: AppActionContext) throws {
        let room = try context.room(invocation)
        let order = context.services.machines.local.store.profileIDs
        guard let from = order.firstIndex(of: room.id), order.indices.contains(from + delta) else {
            throw ActionFailure.invalidTarget(RoomStrings.roomAtEdge)
        }
        let insertion = delta > 0 ? from + 2 : from - 1
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
