import CmuxNextPages
import Foundation

/// The agent page's granted video and audio on the shared page host:
/// `cmux-page://cmux.agent/__media/<token>.<ext>`, the same files and the same byte ranges the old
/// pane host serves at `cmux-agent://pane/__media/` (``AgentPaneSchemeHandler/readSlice(of:range:)``),
/// so a player streams a file of any size. A token the host never granted is a 404. WebKit and
/// Chromium both ask in ranges (the page host passes the `Range` header); a whole-body request
/// gets a 404, never a whole file read.
@MainActor
final class AgentPageMediaResource: PageDynamicResourceSource, PageRangedResourceSource {
    static let shared = AgentPageMediaResource()
    static let prefix = "__media"

    func resource(for request: PageResourceRequest) async -> PageResource? { nil }

    func rangedResource(for request: PageResourceRequest, range: String?) async -> PageRangedResource? {
        guard let file = AgentPaneSchemeHandler.mediaFile(for: request.url),
              let slice = await AgentPaneSchemeHandler.readSlice(of: file, range: range) else { return nil }
        return PageRangedResource(status: slice.status, headers: slice.headers, data: slice.data)
    }
}
