import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Strings of the room handlers and prompts (Resources/Rooms.xcstrings).
/// A room is the daemon's profile (plans/cmux-next/data-model.md).
nonisolated enum RoomStrings {
    static func defaultName(_ number: Int) -> String {
        String(format: text("rooms.defaultName", "Space %lld"), locale: Locale.current, number)
    }
    static var renameTitle: String { text("rooms.renameTitle", "Rename Space") }
    static func deleteTitle(_ name: String) -> String { String(format: text("rooms.deleteTitle", "Delete space “%@”?"), name) }
    /// The count line of the Delete Space question (none for no workspace).
    static func deleteClosesBody(_ count: Int) -> String {
        String(localized: "rooms.deleteClosesBody", defaultValue: "Its \(count) workspaces close.", table: "Rooms", bundle: .module)
    }
    /// The toast after Delete Space (RECOVERABLE-BY-DEFAULT).
    static func deletedToast(_ name: String) -> String { String(format: text("rooms.deletedToast", "Space “%@” deleted"), name) }
    static var delete: String { text("rooms.delete", "Delete") }
    static func noRoom(_ id: String) -> String { String(format: text("rooms.refusal.noRoom", "no space %@"), id) }
    static var defaultCannotBeDeleted: String { text("rooms.refusal.defaultCannotBeDeleted", "the Default space cannot be deleted") }
    static var roomAtEdge: String { text("rooms.refusal.atEdge", "the space is already at the edge") }
    static var noOtherRoom: String { text("rooms.refusal.noOtherRoom", "there is no space that way") }
    static var iconArgumentRequired: String { text("rooms.refusal.iconRequired", "an icon argument (SF Symbol name or one emoji) is required") }
    static var roomArgumentRequired: String { text("rooms.refusal.roomRequired", "a space argument is required") }
    static var alreadyInRoom: String { text("rooms.refusal.alreadyInRoom", "the workspace is already in that space") }
    static var envMustBeObject: String { text("rooms.refusal.envMustBeObject", "env must be a JSON object of strings") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Rooms", bundle: .module)
    }
}

/// Delete Space (SPACE-DELETE-CLOSES-ITS-WORKSPACES, RECOVERABLE-BY-DEFAULT):
/// the workspaces it closes, its question and its Reopen toast.
enum RoomConfirmation {
    /// The workspaces of this Mac that deleting `room` closes: the ones no
    /// other room shows (the daemon's rule), never the home workspace.
    @MainActor
    static func closing(_ room: ProfileID, _ context: AppActionContext) -> [WorkspaceModel] {
        let machines = context.services.machines
        guard let membership = WindowProfiles.membership(machines), let session = machines.local.store.registryID else { return [] }
        return machines.local.store.workspaces.filter { workspace in
            workspace.kind != "home"
                && membership.closes(RoomMembership.Workspace(session: session, key: workspace.key?.rawValue ?? workspace.id), deleting: room)
        }
    }

    /// The question asked only when a closing workspace runs a program and
    /// `app.warnBeforeClosingTab` is on (the rule of every close); a move
    /// closes nothing and never asks. Nil runs without asking.
    @MainActor
    static func prompt(_ invocation: ActionInvocation, _ context: AppActionContext) async -> DestructiveConfirmation.Prompt? {
        guard context.services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback,
              let room = try? context.room(invocation), !room.isDefault,
              (try? context.optionalRoom(invocation["moveTo"])).flatMap({ $0 }) == nil else { return nil }
        let closing = closing(room.id, context)
        let programs = await DestructiveConfirmation.runningPrograms(
            of: closing.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs), on: context.services.machines.local)
        guard !programs.isEmpty else { return nil }
        let body = [RoomStrings.deleteClosesBody(closing.count), ConfirmationStrings.closeWorkspaceBody(programs.joined(separator: ", "))]
        return DestructiveConfirmation.Prompt(title: RoomStrings.deleteTitle(room.name), body: body.joined(separator: "\n"),
                                              button: RoomStrings.delete, suppresses: CmuxConfigSnapshot.warnBeforeClosingTabPath)
    }

    static let toastID = "space-deleted"

    /// "Space “X” deleted · Reopen" in the active window; Reopen restores
    /// the space and its workspaces (closed group `closedID`).
    @MainActor
    static func showDeleted(_ name: String, closedID: String, services: AppServices) {
        guard let window = services.windows.active?.window else { return }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: RoomStrings.deletedToast(name), action: .reopen()), in: window)
        handle.onAction = { [weak services] in
            guard let services else { return }
            if let entry = DaemonClosedHistory.entry(closedID, in: services) {
                DaemonClosedHistory.reopen(entry, services: services)
            } else {
                services.machines.local.send("reopen-space") { try await $0.state.reopenClosed(closedID) }
            }
        }
    }
}
