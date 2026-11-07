import CmuxNextPages
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

    /// - Parameters:
    ///   - session: The chat the page shows now, nil for none.
    ///   - allowed: Whether that chat may keep its copy (false in an incognito window).
    init(session: @escaping @MainActor () -> String?, allowed: @escaping @MainActor () -> Bool) {
        self.session = session
        self.allowed = allowed
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.prefix == AgentPaneChatSnapshots.prefix, request.path == ["chat.js"] else { return nil }
        return PageResource(data: await AgentPaneTailCache.shared.snapshots.script(for: session(), allowed: allowed()),
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
