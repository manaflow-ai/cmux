/// The caller path requesting native runtime surface creation.
enum RuntimeSurfaceCreationSource {
    /// Normal creation from a ready terminal view.
    case normal

    /// Creation from the paced session-restore queue.
    case scheduledRestore
}
