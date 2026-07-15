import Foundation

/// Localized error messages for the `note.*` socket RPCs
/// (TerminalController+Notes.swift).
enum NoteRPCMessage {
    static let missingSlug = String(localized: "rpc.note.error.missingSlug", defaultValue: "Missing 'slug' parameter")
    static let emptySlug = String(localized: "rpc.note.error.emptySlug", defaultValue: "slug must not be empty")
    static let tabManagerUnavailable = String(localized: "rpc.note.error.tabManagerUnavailable", defaultValue: "TabManager not available")
    static let openFailed = String(localized: "rpc.note.error.openFailed", defaultValue: "Failed to open note")
    static let workspaceNotFound = String(localized: "rpc.note.error.workspaceNotFound", defaultValue: "Workspace not found")
    static let noteNotFound = String(localized: "rpc.note.error.noteNotFound", defaultValue: "Note not found")
    static let accessFailed = String(localized: "rpc.note.error.accessFailed", defaultValue: "I/O error while accessing the note")
    static let createFailed = String(localized: "rpc.note.error.createFailed", defaultValue: "Failed to create note file")
    static let focusSurfaceMissing = String(localized: "rpc.note.error.focusSurfaceMissing", defaultValue: "No focused surface to split")
    static let sourceSurfaceNotFound = String(localized: "rpc.note.error.sourceSurfaceNotFound", defaultValue: "Source surface not found")
    static let surfaceCreateFailed = String(localized: "rpc.note.error.surfaceCreateFailed", defaultValue: "Failed to create note surface")
    static let listFailed = String(localized: "rpc.note.error.listFailed", defaultValue: "Failed to list notes")
    static let pathFailed = String(localized: "rpc.note.error.pathFailed", defaultValue: "Failed to resolve note path")
    static let readFailed = String(localized: "rpc.note.error.readFailed", defaultValue: "Failed to read note")
    static let writeFailed = String(localized: "rpc.note.error.writeFailed", defaultValue: "Failed to write note")
    static let appendFailed = String(localized: "rpc.note.error.appendFailed", defaultValue: "Failed to append note")
    static let deleteFailed = String(localized: "rpc.note.error.deleteFailed", defaultValue: "Failed to delete note")
    static let missingContent = String(localized: "rpc.note.error.missingContent", defaultValue: "Missing 'content' parameter")
    static let remoteUnavailable = String(localized: "rpc.note.error.remoteUnavailable", defaultValue: "Notes are not available for remote workspaces")
    static let terminalAttachRequiresTerminal = String(
        localized: "rpc.note.error.terminalAttachRequiresTerminal",
        defaultValue: "Cannot attach a terminal note to a non-terminal surface"
    )

    static func invalidDirection(_ direction: String) -> String {
        String(
            format: String(
                localized: "rpc.note.error.invalidDirection",
                defaultValue: "Invalid direction '%@' (left|right|up|down)"
            ),
            locale: .current,
            direction
        )
    }

    static func invalidAttachMode(_ mode: String) -> String {
        String(
            format: String(
                localized: "rpc.note.error.invalidAttachMode",
                defaultValue: "Invalid attach mode '%@' (none|workspace|surface|terminal)"
            ),
            locale: .current,
            mode
        )
    }

    static func invalidBoolean(_ name: String) -> String {
        String(
            format: String(
                localized: "rpc.note.error.invalidBoolean",
                defaultValue: "Invalid boolean for '%@' (true|false)"
            ),
            locale: .current,
            name
        )
    }
}
