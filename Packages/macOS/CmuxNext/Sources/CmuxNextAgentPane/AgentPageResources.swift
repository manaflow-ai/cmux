import CmuxNextPages
import CmuxNextSettings
import Foundation

/// One agent page's generated resources: its granted media (``AgentPageMediaResource``, the app's
/// one table) and its chat's drawn copy at `__snapshot/chat.js` (``AgentPaneChatSnapshots``), the
/// script the document runs before its bundle. Per page, because the copy is the chat's this page
/// shows: `session` is read when the document asks, so a restored tab's chat (its model's session
/// from the moment it was made) answers, and a page that shows no chat yet answers null.
@MainActor
final class AgentPageResources: PageDynamicResourceSource, PageRangedResourceSource {
    private let session: @MainActor () -> String?
    private let allowed: @MainActor () -> Bool
    /// The theme key the page would get now (``AgentPageEvent/theme(_:surface:)``'s `key`), nil
    /// until the pane sets it: the page draws its copy only under the theme it was drawn in.
    var themeKey: @MainActor () -> String? = { nil }

    /// - Parameters:
    ///   - session: The chat the page shows now, nil for none.
    ///   - allowed: Whether that chat may keep its copy (false in an incognito window).
    init(session: @escaping @MainActor () -> String?, allowed: @escaping @MainActor () -> Bool) {
        self.session = session
        self.allowed = allowed
        // The chat's copy is read from when the page is made, while its document loads: at launch
        // the main thread is busy, and the request then waits on no disk read of its own.
        if let chat = session(), !chat.isEmpty {
            // task-owner: one bounded disk read per page made; kept until the document asks for it
            ahead = (chat, Task { await AgentPaneTailCache.shared.snapshots.snapshot(for: chat) })
        }
    }

    /// The copy read ahead for the chat the page showed when made; the first request takes it.
    private var ahead: (session: String, read: Task<JSONValue?, Never>)?

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.prefix == AgentPaneChatSnapshots.prefix, request.path == ["chat.js"] else { return nil }
        let chat = session()
        let read = ahead.flatMap { $0.session == chat ? $0.read : nil }
        ahead = nil
        return PageResource(data: await AgentPaneTailCache.shared.snapshots.script(for: chat, allowed: allowed(), themeKey: themeKey(), read: read),
                            mimeType: "text/javascript")
    }

    /// The copy answers whole (a script is never asked in ranges); media answers as it always has.
    func rangedResource(for request: PageResourceRequest, range: String?) async -> PageRangedResource? {
        if request.prefix == AgentPaneChatSnapshots.prefix {
            guard let script = await resource(for: request) else { return nil }
            return PageRangedResource(status: 200, headers: ["Content-Type": "text/javascript", "Cache-Control": "no-store",
                                                             "Content-Length": String(script.data.count)],
                                      data: script.data)
        }
        return await AgentPageMediaResource.shared.rangedResource(for: request, range: range)
    }
}
