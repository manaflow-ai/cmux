import Foundation

/// The main-thread proof of Quick Look's panel-control callbacks (``FilesPaneView``'s
/// `beginPreviewPanelControl` and `endPreviewPanelControl`). QLPreviewPanel is an AppKit panel and
/// calls them on the main thread, so the work runs inline, before the call returns; a call off main
/// (never seen) hops to the main actor instead of trapping.
nonisolated struct QuickLookControlCall: Sendable {
    /// Runs `body` on the main actor: at once on the main thread, else in a main-actor task.
    func run(_ body: @escaping @MainActor @Sendable () -> Void) {
        guard Thread.isMainThread else {
            Task { @MainActor in body() }
            return
        }
        // main-proof: checked Thread.isMainThread just above.
        MainActor.assumeIsolated { body() }
    }
}
