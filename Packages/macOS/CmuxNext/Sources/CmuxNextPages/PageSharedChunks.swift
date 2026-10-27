import Foundation

/// `cmux-page://cmux.shared/` (``PageID/sharedHost``): the content-hashed chunks every page the app
/// ships imports (React, the design system), so one file has one URL whichever page asks it. Chrome
/// serves `chrome://resources` to its WebUI pages the same way
/// (content/browser/webui/shared_resources_data_source.cc).
///
/// It is never a page:
/// - It serves only `.js` and `.css` files inside its root (`Resources/pages/_shared`, or the active
///   web update's copy), so no response is a document, and it has no dynamic prefixes, so no page
///   instance's generated files (a repository file of the Markdown page) are reachable from it.
/// - It answers only a CORS request from a first-party page origin (``allowedOrigin(_:)``), and its
///   `Access-Control-Allow-Origin` is that origin, with `Vary: Origin`
///   (`SharedResourcesDataSource::GetAccessControlAllowOriginForOrigin`,
///   content/browser/webui/url_data_manager_backend.cc). A web page, an app page, an opaque origin
///   and a request with no `Origin` get no answer.
/// - A navigation to it is refused, and its policy (``PageID/sharedChunkPolicy``) forbids framing.
///
/// Chromium serves it from the CEF shim by the same rules (CEFShim `SharedChunkFactory`,
/// cmux_page_path.h).
nonisolated enum PageSharedChunks {
    /// The file types the root serves.
    static let servedExtensions: Set<String> = ["js", "css"]

    /// The shared folder in this module's resource bundle, nil when the page build wrote none.
    static var bundledRoot: URL? {
        Bundle.module.url(forResource: "_shared", withExtension: nil, subdirectory: "pages")
    }

    /// The shared folder of a web-dev.json overlay (``WebDevOverride/overlay``), beside its pages.
    static let overlayFolder = "pages/_shared"

    /// The Debug override of the shared folder (`CMUX_NEXT_PAGE_ROOT_cmux_shared`, the page roots'
    /// variable for this host), else nil: the `pages/_shared` of the build whose page a
    /// `CMUX_NEXT_PAGE_ROOT_<id>` override loads (agent-stream-e2e.py passes both per variant).
    static var debugRoot: URL? {
        #if DEBUG
        let name = "CMUX_NEXT_PAGE_ROOT_" + PageID.sharedHost.replacingOccurrences(of: ".", with: "_")
        guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }

    /// The folders a shared file is read from, in order, each once: the live overlay's
    /// (``overlayFolder``), the Debug override (``debugRoot``), the active web update's copy of the
    /// bundled folder, the bundled folder. A chunk's name is its content hash, so a name is one file in
    /// every folder that holds it: a page from an overlay or another build gets its own chunks, and a
    /// bundled page still gets the bundled ones.
    static func roots(overlay: URL?, debug: URL?, update: URL, bundled: URL) -> [URL] {
        let candidates = [overlay?.appending(path: overlayFolder, directoryHint: .isDirectory), debug, update, bundled]
        var seen: Set<String> = []
        return candidates.compactMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Whether `url` is at the shared origin.
    static func isShared(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == PageDescriptor.scheme && url.host?.lowercased() == PageID.sharedHost
    }

    /// The `Access-Control-Allow-Origin` a request with the `Origin` header `origin` gets: the origin
    /// itself when it is a first-party page origin (`cmux-page://cmux.<page>`, serialized exactly:
    /// lowercase, no port, no path), else nil. The shared origin is not a page, so it never reads itself.
    static func allowedOrigin(_ origin: String?) -> String? {
        let prefix = PageDescriptor.scheme + "://"
        guard let origin, origin.hasPrefix(prefix) else { return nil }
        let host = String(origin.dropFirst(prefix.count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.unicodeScalars.allSatisfy(allowed.contains),
              PageID.isReserved(host), host != PageID.sharedHost else { return nil }
        return origin
    }

    /// The `Access-Control-Allow-Origin` of a request for `url` with the `Origin` header `origin`
    /// whose top document is `mainDocument`: nil for another origin than the shared one, a navigation
    /// to the shared origin, or an origin that may not read it (``allowedOrigin(_:)``).
    static func allowedOrigin(for url: URL, origin: String?, mainDocument: URL?) -> String? {
        guard isShared(url), !isShared(mainDocument) else { return nil }
        return allowedOrigin(origin)
    }

    /// The `.js` or `.css` file `url` names inside `root`, nil for any other type, a `.` or `..`
    /// component, or a path (symlinks resolved) that leaves `root`.
    static func file(for url: URL, root: URL) -> URL? {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last, servedExtensions.contains((name as NSString).pathExtension),
              !components.contains(where: { $0 == ".." || $0 == "." }),
              let file = PageSchemeHandler.fileURL(components: components, root: root),
              servedExtensions.contains(file.pathExtension) else { return nil }
        return file
    }

    /// The response for a shared file, readable by `allowedOrigin` only.
    static func reply(url: URL, allowedOrigin: String, body: Data, file: URL) -> PageSchemeHandler.Reply {
        PageSchemeHandler.reply(url: url, policy: PageID.sharedChunkPolicy, status: 200,
                                mimeType: PageSchemeHandler.mimeType(forExtension: file.pathExtension), body: body,
                                extra: ["Access-Control-Allow-Origin": allowedOrigin, "Vary": "Origin",
                                        "Cross-Origin-Resource-Policy": "same-origin"])
    }
}
