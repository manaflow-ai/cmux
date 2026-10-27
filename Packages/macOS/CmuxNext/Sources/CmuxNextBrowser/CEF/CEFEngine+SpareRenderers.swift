import Foundation

/// The Chromium spare renderers (p07-memory-113): the one-spare rule and what `debug.memory` lists.
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

    /// The renderer client ids of every Chromium page the runtime holds (browser tabs, cmux pages, popups
    /// and the spare windows' placeholders). A renderer helper outside this set runs no page the runtime
    /// holds: at Home that is Chromium's own spare renderer (`debug.memory`); a DevTools front end or a
    /// worker-only renderer would be outside it too. One shim read per page.
    public var rendererClientsInUse: Set<Int32> {
        var clients = Set<Int32>()
        for tab in CEFRuntime.shared.tabsByBrowser.values {
            if case .chromiumRendererClients(let ids) = tab.contentProcesses { clients.formUnion(ids) }
        }
        return clients
    }
}
