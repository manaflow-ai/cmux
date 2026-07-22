import Observation

/// Orders viewer loading after the destination has entered the view hierarchy.
@Observable
@MainActor
final class ChatArtifactViewerPresentationCoordinator {
    private(set) var isPresented = false
    private(set) var generation = 0

    /// Records a new appearance before any route-specific loader can run.
    func present() {
        guard !isPresented else { return }
        isPresented = true
        generation &+= 1
    }

    /// Records that the destination has left the view hierarchy.
    func dismiss() {
        isPresented = false
    }

    /// Starts content resolution only after presentation has had a scheduler turn.
    ///
    /// - Parameter load: The shared stat, fetch, and route-resolution operation.
    /// - Returns: Whether the operation started for a presented destination.
    func loadAfterPresentation(
        _ load: @MainActor () async -> Void
    ) async -> Bool {
        guard isPresented else { return false }
        await Task.yield()
        guard isPresented, !Task.isCancelled else { return false }
        await load()
        return true
    }
}
