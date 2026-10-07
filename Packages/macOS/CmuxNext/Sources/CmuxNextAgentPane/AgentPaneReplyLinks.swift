public import AppKit
public import CmuxNextSettings
public import Foundation

/// What cmux already knows about a web page a reply links to: its site's favicon (PNG) and the
/// page's title, from the user's own browsing. Never fetched for a chip (D4).
public nonisolated struct AgentPaneReplySite: Equatable, Sendable {
    public var iconPNG: Data?
    public var title: String?

    public init(iconPNG: Data? = nil, title: String? = nil) {
        self.iconPNG = iconPNG
        self.title = title
    }
}

/// The App's side of the reply link requests (``AgentPaneReplyRequest``): the settings, the
/// favicon and title lookup, the outside-root confirmation sheet, and the effects. Each has a safe
/// default, so a host that wires nothing shows globes and plain text and opens nothing outside.
@MainActor public final class AgentPaneReplyLinks {
    /// `agentPane.links.outsideRoots` and `agentPane.images.remote`, read on every request.
    public var settings: @MainActor () -> AgentPaneReplySetting = { .fallback }
    /// The site of each URL (key: the URL as the page sent it), from cmux's own caches.
    public var sites: @MainActor ([URL]) -> [URL: AgentPaneReplySite] = { _ in [:] }
    /// Asks the user to open a file outside the project (the view's native sheet).
    public var confirmOutside: (@MainActor (_ path: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Shows a folder (in Finder: nothing in it runs).
    public var revealFolder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    public var browsers: any AgentPaneBrowserApps = AgentPaneWorkspaceBrowsers()
    var fetcher: any AgentPaneImageFetching = AgentPaneSafeFetch()
    let choices = AgentPaneBrowserChoices()
    /// The home folder for `~/` and the deny list (tests replace it).
    var home = NSHomeDirectory()

    public init() {}
}

extension AgentPaneModel {
    /// The folders a reply's paths may name for an open: the pane's roots and the folders the
    /// user added (the same as `file.open`).
    func replyPaths() -> AgentPaneReplyPaths {
        AgentPaneReplyPaths(roots: fileOpenRoots(), home: replyLinks.home, base: sessionRoots().first ?? primaryRoot())
    }

    /// The reply for one reply link request.
    func respond(to request: AgentPaneReplyRequest) async -> [String: Any] {
        switch request {
        case .inspect(let paths, let urls):
            let resolver = replyPaths()
            var places: [String: Any] = [:]
            for path in paths {
                guard let resolved = resolver.resolve(path) else { continue }
                places[path] = ["place": resolved.place.rawValue, "folder": resolved.isFolder]
            }
            let parsed = urls.compactMap { text in AgentPaneReplyRequest.webURL(text).map { (text, $0) } }
            let found = parsed.isEmpty ? [:] : replyLinks.sites(parsed.map(\.1))
            var sites: [String: Any] = [:]
            for (text, url) in parsed {
                guard let site = found[url] else { continue }
                var entry: [String: Any] = [:]
                if let png = site.iconPNG, png.count <= 64 << 10 { entry["icon"] = "data:image/png;base64," + png.base64EncodedString() }
                if let title = site.title, !title.isEmpty { entry["title"] = String(title.prefix(300)) }
                if !entry.isEmpty { sites[text] = entry }
            }
            let setting = replyLinks.settings()
            return AgentPaneReply.success([
                "paths": places, "sites": sites,
                "policy": ["outsideRoots": setting.outsideRoots.rawValue, "remoteImages": setting.remoteImages.rawValue],
            ])
        case .openPath(let path):
            return Self.replyResult(await openReplyPath(path))
        case .loadImage(let src):
            return await loadReplyImage(src)
        case .listBrowsers:
            return AgentPaneReply.success(["browsers": replyLinks.choices.list(from: replyLinks.browsers)])
        case .openIn(let url, let browserId):
            if browserId == "cmux" {
                guard transport.gestures.consume() else { return Self.replyFailure(.gestureRequired) }
                guard let onOpenPreview, onOpenPreview(url) else { return Self.replyFailure(.openFailed) }
                return AgentPaneReply.success()
            }
            guard let app = replyLinks.choices.app(browserId) else { return Self.replyFailure(.browserUnknown) }
            guard transport.gestures.consume() else { return Self.replyFailure(.gestureRequired) }
            replyLinks.browsers.open(url, withApplicationAt: app)
            return AgentPaneReply.success()
        }
    }

    /// Opens a path chip (D4): the deny list first, then a gesture; inside a root it opens in
    /// cmux's file pages (a folder in Finder); outside, `agentPane.links.outsideRoots` decides.
    func openReplyPath(_ text: String) async -> Result<Void, AgentPaneReplyError> {
        guard let resolved = replyPaths().resolve(text) else { return .failure(.pathInvalid) }
        switch resolved.place {
        case .denied: return .failure(.pathDenied)
        case .missing: return .failure(.pathInvalid)
        case .root: break
        case .outside:
            switch replyLinks.settings().outsideRoots {
            case .text: return .failure(.pathOutsideRoots)
            case .open: break
            case .confirm:
                guard transport.gestures.consume() else { return .failure(.gestureRequired) }
                guard await confirmOutside(resolved.path) else { return .failure(.notConfirmed) }
                return await openResolved(resolved.path)
            }
        }
        guard transport.gestures.consume() else { return .failure(.gestureRequired) }
        return await openResolved(resolved.path)
    }

    /// Opens `path` after every check: a folder in Finder, a file in the pane's file pages.
    private func openResolved(_ path: String) async -> Result<Void, AgentPaneReplyError> {
        guard let canonical = AcpmuxPathPolicy.canonical(path) else { return .failure(.pathInvalid) }
        // The link may have changed between the check and now: check the secret names again.
        guard !replyPaths().isDenied(canonical) else { return .failure(.pathDenied) }
        if AcpmuxPathPolicy.isDirectory(canonical) {
            replyLinks.revealFolder(URL(fileURLWithPath: canonical, isDirectory: true))
            return .success(())
        }
        guard let url = AgentPaneFileOpen.resolve(canonical), let onOpenFile else { return .failure(.pathInvalid) }
        // A tab is cmux's file pages, which show any file as text and never run it.
        return await onOpenFile(url, .tab) ? .success(()) : .failure(.openFailed)
    }

    private func confirmOutside(_ path: String) async -> Bool {
        guard let ask = replyLinks.confirmOutside else { return false }
        return await withCheckedContinuation { continuation in
            ask(path) { continuation.resume(returning: $0) }
        }
    }

    /// A reply image (D5): a file inside the roots, read by the host; or an https image fetched
    /// under the network rules, after a click unless `agentPane.images.remote` is `always`.
    func loadReplyImage(_ src: String) async -> [String: Any] {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" {
            guard scheme == "https", AgentPaneSafeFetch.isFetchable(url) else { return Self.replyFailure(.imageRefused) }
            switch replyLinks.settings().remoteImages {
            case .never: return Self.replyFailure(.imageRefused)
            case .always: break
            case .click: guard transport.gestures.consume() else { return Self.replyFailure(.gestureRequired) }
            }
            switch await replyLinks.fetcher.fetch(url) {
            case .success(let data): return Self.replyImage(await AgentPaneReplyImages.remote(data))
            case .failure(let error): return Self.replyFailure(error)
            }
        }
        guard let resolved = replyPaths().resolve(src) else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .root: return Self.replyImage(await AgentPaneReplyImages.local(resolved.path))
        case .denied: return Self.replyFailure(.pathDenied)
        case .outside: return Self.replyFailure(.pathOutsideRoots)
        case .missing: return Self.replyFailure(.pathInvalid)
        }
    }

    static func replyImage(_ result: Result<String, AgentPaneReplyError>) -> [String: Any] {
        switch result {
        case .success(let url): AgentPaneReply.success(["src": url])
        case .failure(let error): replyFailure(error)
        }
    }

    static func replyResult(_ result: Result<Void, AgentPaneReplyError>) -> [String: Any] {
        switch result {
        case .success: AgentPaneReply.success()
        case .failure(let error): replyFailure(error)
        }
    }

    static func replyFailure(_ error: AgentPaneReplyError) -> [String: Any] {
        AgentPaneReply.failure(code: error.rawValue, message: replyFailedMessage, details: nil, retryable: nil, origin: "native")
    }

    static var replyFailedMessage: String {
        String(localized: "agentPane.error.replyLink", defaultValue: "The app refused this link.", bundle: .module)
    }
}
