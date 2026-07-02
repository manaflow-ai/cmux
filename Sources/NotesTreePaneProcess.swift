import Foundation

/// One process sitting on a pane TTY.
struct NotesTreePaneProcess: Equatable, Sendable {
    var pid: Int
    var tty: String
    var startedAt: TimeInterval
    var command: String
}
