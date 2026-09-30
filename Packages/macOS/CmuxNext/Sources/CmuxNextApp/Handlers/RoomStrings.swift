import CmuxNextActions
import Foundation

/// Strings of the room handlers and prompts (Resources/Rooms.xcstrings).
/// A room is the daemon's profile (plans/cmux-next/data-model.md).
nonisolated enum RoomStrings {
    static func defaultName(_ number: Int) -> String {
        String(format: text("rooms.defaultName", "Room %lld"), locale: Locale.current, number)
    }
    static var renameTitle: String { text("rooms.renameTitle", "Rename Room") }
    static var iconTitle: String { text("rooms.iconTitle", "Room Icon (SF Symbol name or one emoji)") }
    static func deleteTitle(_ name: String) -> String { String(format: text("rooms.deleteTitle", "Delete room “%@”?"), name) }
    static var deleteReturnsBody: String {
        text("rooms.deleteReturnsBody", "Its workspaces stay open and return to the rooms that follow their machines.")
    }
    static func deleteMovesBody(_ target: String) -> String {
        String(format: text("rooms.deleteMovesBody", "Its workspaces and groups move to “%@”."), target)
    }
    static var delete: String { text("rooms.delete", "Delete") }
    static func noRoom(_ id: String) -> String { String(format: text("rooms.refusal.noRoom", "no room %@"), id) }
    static var defaultCannotBeDeleted: String { text("rooms.refusal.defaultCannotBeDeleted", "the Default room cannot be deleted") }
    static var roomAtEdge: String { text("rooms.refusal.atEdge", "the room is already at the edge") }
    static var noOtherRoom: String { text("rooms.refusal.noOtherRoom", "there is no room that way") }
    static var iconArgumentRequired: String { text("rooms.refusal.iconRequired", "an icon argument (SF Symbol name or one emoji) is required") }
    static var roomArgumentRequired: String { text("rooms.refusal.roomRequired", "a room argument is required") }
    static var alreadyInRoom: String { text("rooms.refusal.alreadyInRoom", "the workspace is already in that room") }
    static var envMustBeObject: String { text("rooms.refusal.envMustBeObject", "env must be a JSON object of strings") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Rooms", bundle: .module)
    }
}

/// The Delete Room question: how many workspaces close, or where they go.
enum RoomConfirmation {
    @MainActor
    static func prompt(_ invocation: ActionInvocation, _ context: AppActionContext) -> DestructiveConfirmation.Prompt? {
        guard let room = try? context.room(invocation), !room.isDefault else { return nil }
        let body = (try? context.optionalRoom(invocation["moveTo"])).flatMap { $0 }.map { RoomStrings.deleteMovesBody($0.name) }
            ?? RoomStrings.deleteReturnsBody
        return DestructiveConfirmation.Prompt(title: RoomStrings.deleteTitle(room.name), body: body, button: RoomStrings.delete)
    }
}
