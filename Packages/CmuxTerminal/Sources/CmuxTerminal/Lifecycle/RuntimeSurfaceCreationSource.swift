/// The caller path requesting native runtime surface creation.
enum RuntimeSurfaceCreationSource: Sendable {
    /// Normal creation from a ready terminal view.
    case normal

    /// Creation demanded by immediate user input on a visible terminal.
    case inputDemand

    /// Creation from the paced session-restore queue.
    case scheduledRestore
}
