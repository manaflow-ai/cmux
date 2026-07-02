import Foundation

/// Everything the app layer can tell the store about agents in this
/// workspace's panes for one refresh pass.
struct NotesTreeObservation: Equatable, Sendable {
    var sessions: [NotesTreeObservedSession] = []
    var anonymousAgents: [NotesTreeAnonymousAgentObservation] = []
    var terminals: [NotesTreeObservedTerminal] = []
}
