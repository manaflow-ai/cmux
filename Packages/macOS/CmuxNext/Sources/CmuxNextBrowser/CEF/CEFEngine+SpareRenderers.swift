import Foundation

/// The Chromium spare renderers: the one-spare rule and what `debug.memory` lists.
extension CEFEngine {
    /// The default-off feature `chromiumOneSpareRenderer`: at most one Chromium spare renderer
    /// (``CEFSpareWindow/placeholderIsTheSpare``). Set before Chromium starts, like ``setRendererlessSpareWindows(_:)``.
    public func setOneSpareRenderer(_ on: Bool) {
        CEFRuntime.shared.spareWindow.oneSpareRenderer = on
    }

    /// The untaken spare Chromium windows for `debug.memory`: `chromium_window` (the default profile's)
    /// and `chromium_pages_window` (the cmux pages profile's), each with its placeholder's renderer
    /// client ids, empty while it holds no renderer.
    public var spareWindowRenderers: [(pool: String, rendererClients: [Int32])] {
        CEFRuntime.shared.spareWindow.untakenSpares.map { spare in
            (spare.kind == .browser ? "chromium_window" : "chromium_pages_window", spare.rendererClients)
        }
    }

    /// The renderer client ids that host a frame of any browser Chromium holds: tabs, cmux pages, popups,
    /// the spare windows' placeholders and DevTools front ends (``rendererFrames``, one shim call). A
    /// renderer helper outside it hosts no frame: Chromium's own spare, or a renderer whose navigation has
    /// not committed or that holds only workers or back/forward-cached pages. Nil until Chromium is ready
    /// and in host mode, where the renderers are not this process's helpers.
    public var rendererClientsWithFrames: Set<Int32>? {
        guard isRunning, let frames = rendererFrames else { return nil }
        return Set(frames.entries.map(\.clientID))
    }
}
