import Foundation

extension CEFEngine {
    /// Runs `action` after every check of the renderers that host cmux pages (``CEFPageRendererGC``: within
    /// 10 s of a cmux page closing), so the App can recycle the chat renderer (``CEFChatRendererRecycle``).
    /// One action; a second call replaces the first.
    public func afterPageRendererChecks(_ action: @escaping @MainActor () async -> Void) {
        CEFRuntime.shared.pageRendererGC.checked = action
    }

    /// Chromium is shutting down (the app quits): no page is built again.
    public var isShuttingDown: Bool { CEFRuntime.shared.shutdownSequence != nil }
}
