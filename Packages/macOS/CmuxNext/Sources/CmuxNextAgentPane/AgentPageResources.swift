import CmuxNextPages
import CmuxNextSettings
import Foundation

/// One agent page's generated resources: its granted media (``AgentPageMediaResource``, the app's
/// one table) and its chat's drawn copy at `__snapshot/chat.js` (``AgentPaneChatSnapshots``), the
/// script the document runs before its bundle. Per page, because the copy is the chat's this page
/// shows: `session` is read when the document asks, so a restored tab's chat (its model's session
/// from the moment it was made) answers, and a page that shows no chat yet answers null.
@MainActor
final class AgentPageResources: PageDynamicResourceSource, PageRangedResourceSource, PageReadyResourceSource {
    private let session: @MainActor () -> String?
    private let allowed: @MainActor () -> Bool
    /// The theme key the page would get now (``AgentPageEvent/theme(_:surface:)``'s `key`), nil
    /// until the pane sets it: the page draws its copy only under the theme it was drawn in.
    var themeKey: @MainActor () -> String? = { nil }
    /// The page's app sections, whose bundle images and symbols it serves under `__appbundle/` and
    /// `__appsymbol/` (``AppsPanelsPageProvider``).
    weak var appBundles: AppsPanelsPageProvider?

    /// - Parameters:
    ///   - session: The chat the page shows now, nil for none.
    ///   - allowed: Whether that chat may keep its copy (false in an incognito window).
    init(session: @escaping @MainActor () -> String?, allowed: @escaping @MainActor () -> Bool) {
        self.session = session
        self.allowed = allowed
        // The chat's copy is read from when the page is made, while its document loads: at launch
        // the main thread is busy, and the request then waits on no disk read of its own.
        if let chat = session(), !chat.isEmpty {
            aheadGeneration = AgentPaneTailCache.shared.generation
            // task-owner: one bounded disk read per page made; kept until the document asks for it
            ahead = (chat, Task { [weak self] in
                let kept = await AgentPaneTailCache.shared.snapshots.snapshot(for: chat)
                // Kept only while no request took the read ahead: a request that took it already
                // has this copy, and holding it after would serve it to a later document.
                if let self, self.ahead != nil { self.read = (chat, kept) }
                return kept
            })
        }
    }

    /// The copy being read ahead for the chat the page showed when made, and once read, what was
    /// read (``readyResource(for:)``); the first request takes them. Holds one copy (at most the
    /// store's 1 MiB bound, the page's own is 256k characters) from when the page is made until its
    /// document asks, about a second.
    private var ahead: (session: String, read: Task<JSONValue?, Never>)?
    private var read: (session: String, kept: JSONValue?)?
    /// The chats' lifecycle when the read ahead began: a sign-out since (``AgentPaneTailCache/clear()``)
    /// makes what it read no one's to serve.
    private var aheadGeneration: UInt64 = 0

    /// Whether the copy read ahead is still servable: no sign-out since it was read.
    private var aheadIsCurrent: Bool {
        aheadGeneration == AgentPaneTailCache.shared.generation && AgentPaneTailCache.shared.acceptsTails
    }

    /// The script at once, in the turn Chromium asks, once the read ahead is in (or when the page
    /// shows no chat, or one it may not keep): at launch the main thread runs a long queue, and the
    /// document's copy then waits on no task in it. Before the read is in, the request goes the usual way.
    func readyResource(for request: PageResourceRequest) -> PageResource? {
        guard request.prefix == AgentPaneChatSnapshots.prefix, request.path == ["chat.js"] else { return nil }
        let chat = session()
        let keeps = allowed() && !(chat?.isEmpty ?? true)
        let current = aheadIsCurrent
        guard !keeps || !current || read?.session == chat else { return nil }
        // After a sign-out the copy read before it is dropped, and the page is answered with none.
        let kept = keeps && current ? read?.kept : nil
        (ahead, read) = (nil, nil)
        return PageResource(data: AgentPaneTailCache.shared.snapshots.script(for: chat, allowed: allowed(), themeKey: themeKey(), kept: kept),
                            mimeType: "text/javascript")
    }

    /// Returns once the read ahead is in (a test waits on it).
    func readAhead() async { _ = await ahead?.read.value }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        if [AppsPanelsPageProvider.bundlePrefix, AppsPanelsPageProvider.symbolPrefix].contains(request.prefix) {
            return await appBundles?.resource(for: request)
        }
        guard request.prefix == AgentPaneChatSnapshots.prefix, request.path == ["chat.js"] else { return nil }
        let chat = session()
        let read = aheadIsCurrent ? ahead.flatMap { $0.session == chat ? $0.read : nil } : nil
        (ahead, self.read) = (nil, nil)
        return PageResource(data: await AgentPaneTailCache.shared.snapshots.script(for: chat, allowed: allowed(), themeKey: themeKey(), read: read),
                            mimeType: "text/javascript")
    }

    /// The copy answers whole (a script is never asked in ranges); media answers as it always has.
    func rangedResource(for request: PageResourceRequest, range: String?) async -> PageRangedResource? {
        if request.prefix == AgentPaneChatSnapshots.prefix {
            guard let script = await resource(for: request) else { return nil }
            // The script holds the chat's transcript: only the page's own document may run it, never
            // a cross-origin frame inside it (a localhost preview) loading it as a no-cors script.
            // The WebKit answer; Chromium's shim adds the same two headers to every cmux-page answer
            // (CEFShim cmux_page_path.h `PageResponseHeaders`), the ready one too.
            return PageRangedResource(status: 200, headers: ["Content-Type": "text/javascript", "Cache-Control": "no-store",
                                                             "Content-Length": String(script.data.count),
                                                             "Cross-Origin-Resource-Policy": "same-origin",
                                                             "X-Content-Type-Options": "nosniff"],
                                      data: script.data)
        }
        if [AppsPanelsPageProvider.bundlePrefix, AppsPanelsPageProvider.symbolPrefix].contains(request.prefix) {
            // An app section's image or symbol answers whole: images are small and never asked in ranges.
            guard let image = await appBundles?.resource(for: request) else { return nil }
            var headers = ["Content-Length": String(image.data.count), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
            if let type = image.mimeType { headers["Content-Type"] = type }
            return PageRangedResource(status: 200, headers: headers, data: image.data)
        }
        return await AgentPageMediaResource.shared.rangedResource(for: request, range: range)
    }
}
