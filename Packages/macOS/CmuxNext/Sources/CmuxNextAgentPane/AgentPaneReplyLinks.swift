public import AppKit
public import CmuxNextSettings
public import Foundation
import CmuxNextCompat

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
    public var revealFolder: @MainActor (URL) -> Void = { NSWorkspace.shared.revealInBackground([$0]) }
    /// Selects a file in Finder (the image viewer's Show in Finder).
    public var revealFile: @MainActor (URL) -> Void = { NSWorkspace.shared.revealInBackground([$0]) }
    /// The context menu's Copy Image: replaces the general pasteboard's contents with the item
    /// (``AgentPaneImageCopies/pasteboardItem(_:data:)``); tests record it instead.
    public var copyItem: @MainActor (NSPasteboardItem) -> Bool = { AgentPaneImageCopies.writeGeneral($0) }
    /// Save Image As…: asks where to save the file under the name (the system save panel).
    public var saveFile: @MainActor (_ file: URL, _ name: String) -> Void = { AgentPaneImageCopies.askToSave($0, name: $1) }
    /// Quick Look on a file (the system's preview panel).
    public lazy var quickLookFile: @MainActor (URL) -> Void = { [quickLook = self.quickLook] in quickLook.show($0) }
    /// Whether the person still holds the pointer's button: a page drag (`image.drag`, `file.drag`)
    /// becomes the host's drag only then, so page script alone never starts one.
    public var mouseHeld: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Starts the host's drag of a real file out of the pane (the view's dragging session); false
    /// when there is no pane to drag from.
    public var startDrag: @MainActor (URL) -> Bool = { _ in false }
    /// The Quick Look panel's source for ``quickLookFile``.
    private let quickLook = AgentPaneQuickLook()
    /// Where the image viewer keeps the copies it shows or opens (``AgentPaneImageCopies``).
    public var imageFolder = AgentPaneImageCopies.defaultFolder()
    public var browsers: any AgentPaneBrowserApps = AgentPaneWorkspaceBrowsers()
    /// What the host already has about a pull request (`pr.inspect`), with the age of it; it never
    /// waits on GitHub, and a stale link's refresh runs in the background at most once a minute
    /// however often it is hovered (``AgentReplyPullRequests``).
    public var pullRequest: @MainActor (URL) -> AgentPanePullRequestAnswer = { _ in .init() }
    /// The pull requests a reply links, so the host has them before a card opens.
    public var registerPullRequests: @MainActor ([URL]) -> Void = { _ in }
    var fetcher: any AgentPaneImageFetching = AgentPaneSafeFetch()
    /// The fetch for web video and audio (``AgentPaneSafeFetch/media``).
    var mediaFetcher: any AgentPaneImageFetching = AgentPaneSafeFetch.media
    let choices = AgentPaneBrowserChoices()
    /// The home folder for `~/` and the deny list (tests replace it).
    var home = NSHomeDirectory()

    public init() {}

    /// `pr.inspect`'s reply: the pull request the host already has, when it was read, and whether
    /// a read is running. `null` with no answer yet; the card then shows what the chat knows.
    func respondToPullRequest(_ url: URL) -> [String: Any] {
        let answer = pullRequest(url)
        var reply: [String: Any] = ["pullRequest": answer.pullRequest?.json.foundationObject ?? NSNull(),
                                    "reading": answer.reading]
        if let fetchedAt = answer.fetchedAt { reply["fetchedAt"] = fetchedAt }
        return AgentPaneReply.success(reply)
    }

    /// The link requests a page answers for its link hover card with no chat behind it: the agent
    /// page, and the changelog page's PR chip (`cmux.changelog.<method>`).
    public static let cardMethods: Set<String> = ["browser.list", "browser.openIn", "pr.inspect"]

    /// The reply to one of ``cardMethods`` (any other request is `link.open_failed`), the same on
    /// every page that shows the card. `consumeGesture` spends the person's gesture in that page;
    /// `openInCmux` opens a URL in a cmux browser tab (`browserId` `cmux`), false when nothing opened.
    public func respond(toCard request: AgentPaneReplyRequest, consumeGesture: @MainActor () -> Bool,
                        openInCmux: (@MainActor (URL) -> Bool)?) -> [String: Any] {
        switch request {
        case .listBrowsers:
            return AgentPaneReply.success(["browsers": choices.list(from: browsers)])
        case .inspectPullRequest(let url):
            return respondToPullRequest(url)
        case .openIn(let url, let browserId):
            if browserId == "cmux" {
                guard consumeGesture() else { return AgentPaneModel.replyFailure(.gestureRequired) }
                guard let openInCmux, openInCmux(url) else { return AgentPaneModel.replyFailure(.openFailed) }
                return AgentPaneReply.success()
            }
            guard let app = choices.app(browserId) else { return AgentPaneModel.replyFailure(.browserUnknown) }
            guard consumeGesture() else { return AgentPaneModel.replyFailure(.gestureRequired) }
            browsers.open(url, withApplicationAt: app)
            return AgentPaneReply.success()
        case .inspect, .openPath, .loadImage, .loadMedia, .revealImage, .openImageInPane, .copyImage, .saveImage, .quickLookImage,
             .dragImage, .dragFile:
            return AgentPaneModel.replyFailure(.openFailed)
        }
    }
}

extension AgentPaneModel {
    /// The folders a reply's paths may name for an open: the pane's roots and the folders the
    /// user added (the same as `file.open`). Images also have a read-only scope on this Mac: the
    /// chat's cwd, `/tmp` and home. Keeping it separate means a text path in those folders stays
    /// behind the ordinary outside-root gate. A remote chat never reads this Mac's image roots;
    /// its `image.load` request is handled by the remote wire.
    func replyPaths() -> AgentPaneReplyPaths {
        let base = sessionRoots().first ?? primaryRoot()
        let local = !remoteChat
        let imageRoots = local ? [base, "/tmp", replyLinks.home].compactMap { $0 } : []
        // A remote chat's path spelling belongs to its host. Never retain this Mac's workspace
        // roots as a fallback: a same-named local file must not be read or opened here.
        return AgentPaneReplyPaths(roots: local ? fileOpenRoots() : [], imageRoots: imageRoots, home: replyLinks.home, base: local ? base : nil)
    }

    /// The reply for one reply link request.
    func respond(to request: AgentPaneReplyRequest) async -> [String: Any] {
        switch request {
        case .inspect(let paths, let urls):
            let resolver = replyPaths()
            var places: [String: Any] = [:]
            for path in paths {
                let resolved = AgentPaneReplyPaths.isImagePath(path) ? resolver.resolveImage(path) : resolver.resolve(path)
                guard let resolved else { continue }
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
            // The reply's pull request links are read now, in the background, so a card has them
            // before the pointer arrives and no hover ever waits on GitHub.
            replyLinks.registerPullRequests(urls.compactMap(AgentPaneReplyRequest.pullRequestURL))
            let setting = replyLinks.settings()
            return AgentPaneReply.success([
                "paths": places, "sites": sites,
                "policy": [
                    "outsideRoots": setting.outsideRoots.rawValue, "remoteImages": setting.remoteImages.rawValue,
                    "clickFreeImageHosts": AgentPaneSafeFetch.clickFreeImageHosts.sorted(),
                ],
            ])
        case .openPath(let path):
            return Self.replyResult(await openReplyPath(path))
        case .loadImage(let src, let auto):
            return await loadReplyImage(src, auto: auto)
        case .loadMedia(let src):
            return await loadReplyMedia(src)
        case .listBrowsers, .inspectPullRequest, .openIn:
            return replyLinks.respond(toCard: request, consumeGesture: { transport.gestures.consume() }, openInCmux: onOpenPreview)
        case .revealImage, .openImageInPane, .copyImage, .saveImage, .quickLookImage, .dragImage, .dragFile:
            return await AgentPaneImageCopies.respond(to: request, in: self)
        }
    }

    /// Opens a path chip (D4): the deny list first, then a gesture; inside a root it opens in
    /// cmux's file pages (a folder in Finder); outside, `agentPane.links.outsideRoots` decides.
    func openReplyPath(_ text: String) async -> Result<Void, AgentPaneReplyError> {
        let paths = replyPaths()
        let resolved = AgentPaneReplyPaths.isImagePath(text) ? paths.resolveImage(text) : paths.resolve(text)
        guard let resolved else { return .failure(.pathInvalid) }
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
    /// under the network rules, after a click unless `agentPane.images.remote` is `always` or the
    /// image is from a click-free site (``AgentPaneSafeFetch/isClickFree(_:)``), whose load spends
    /// no gesture and is redirected only within ``AgentPaneSafeFetch/clickFreeImageHosts``. `auto`
    /// is the page's load without a click: one this host does not judge click-free is refused
    /// without spending a gesture the person made for something else.
    func loadReplyImage(_ src: String, auto: Bool = false) async -> [String: Any] {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" {
            guard scheme == "https", AgentPaneSafeFetch.isFetchable(url) else { return Self.replyFailure(.imageRefused) }
            var clickFree = false
            switch replyLinks.settings().remoteImages {
            case .never: return Self.replyFailure(.imageRefused)
            case .always: break
            case .click:
                clickFree = AgentPaneSafeFetch.isClickFree(src)
                guard clickFree || (!auto && transport.gestures.consume()) else { return Self.replyFailure(.gestureRequired) }
            }
            let fetched = clickFree
                ? await replyLinks.fetcher.fetch(url, within: AgentPaneSafeFetch.clickFreeImageHosts)
                : await replyLinks.fetcher.fetch(url)
            switch fetched {
            case .success(let data): return Self.replyImage(await AgentPaneReplyImages.remote(data))
            case .failure(let error): return Self.replyFailure(error)
            }
        }
        let paths = replyPaths()
        guard let resolved = paths.resolveImage(src) else { return Self.replyFailure(.pathInvalid) }
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
