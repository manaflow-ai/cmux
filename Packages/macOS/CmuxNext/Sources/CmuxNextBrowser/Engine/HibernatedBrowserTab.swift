public import AppKit
public import Foundation
public import Observation

/// Stands in for a page that hibernated (its engine page was closed to
/// free memory): keeps the URL, title and favicon, and shows the last
/// snapshot until the App restores the real page. Navigating or reloading
/// asks the host (`onWake`) to restore it first.
///
/// The snapshot is read from the host's bounded image cache when it is
/// needed and held only while the pane shows this page: a placeholder that
/// kept its own full-size picture cost about 7 MB of app memory per
/// hibernated tab, with no bound.
@Observable
public final class HibernatedBrowserTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage?
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// The saved history the real page is recreated with.
    public let restoreState: BrowserRestoreState
    /// The last page pixels, for the pane until the page is back; nil once
    /// the host's cache let them go.
    public var snapshotImage: CGImage? { snapshotSource() }
    private let snapshotSource: @MainActor () -> CGImage?
    /// What woke the page, for the host to apply once it is restored.
    public enum Wake: Sendable, Hashable {
        case load(URL)
        case reload
        case goBack
        case goForward
    }

    /// Called when the user asks for the page (reload, navigate, history):
    /// the host restores it, then applies the request.
    @ObservationIgnored public var onWake: ((Wake) -> Void)?
    @ObservationIgnored public let contentView: NSView

    /// - Parameters:
    ///   - snapshot: The last page pixels from the host's bounded store (decoded off the main thread when shown).
    ///   - preview: A small decoded copy of them, shown in the turn the page enters a window until
    ///     `snapshot` is decoded (nil: the pane waits for the decode).
    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, state: BrowserTabState,
                favicon: NSImage?, restoreState: BrowserRestoreState, snapshot: @escaping @MainActor () -> CGImage?,
                preview: @escaping @MainActor () -> CGImage? = { nil }) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var saved = BrowserTabState(url: state.url, title: state.title)
        saved.canGoBack = state.canGoBack
        saved.canGoForward = state.canGoForward
        saved.zoom = state.zoom
        // The omnibar's lock and the page's icon while it sleeps and wakes, as before it slept.
        saved.security = state.security
        saved.faviconURL = state.faviconURL
        // A muted tab stays muted asleep (the strip's speaker) and wakes muted.
        saved.isAudioMuted = state.isAudioMuted
        self.state = saved
        self.favicon = favicon
        self.restoreState = restoreState
        self.snapshotSource = snapshot
        contentView = SnapshotView(snapshot: snapshot, preview: preview)
    }

    public func load(_ url: URL) { onWake?(.load(url)) }
    public func reload() { onWake?(.reload) }
    public func goBack() { onWake?(.goBack) }
    public func goForward() { onWake?(.goForward) }
    public func stop() {}
    public func setFocused(_ focused: Bool) {}
    public func setContentVisible(_ visible: Bool) {}
    public func snapshot() async throws -> CGImage {
        guard let snapshotImage else { throw BrowserTabError.snapshotUnavailable }
        return snapshotImage
    }
    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        throw BrowserTabError.closed
    }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() {}
}

/// Shows the snapshot only while in a window. A compressed picture decodes when drawn (10 to
/// 30 ms for a full page, a dropped frame on the switch to the tab), so it is decoded off the
/// main thread first, with the small decoded preview shown meanwhile (from the first frame); the
/// decoded pixels are held only while in a window.
private final class SnapshotView: NSImageView {
    private let snapshot: @MainActor () -> CGImage?
    private let preview: @MainActor () -> CGImage?
    private var decoding: Task<Void, Never>?

    init(snapshot: @escaping @MainActor () -> CGImage?, preview: @escaping @MainActor () -> CGImage?) {
        self.snapshot = snapshot
        self.preview = preview
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        decoding?.cancel()
        image = nil
        guard newWindow != nil, let picture = snapshot() else { return }
        if let preview = preview() { image = NSImage(cgImage: preview, size: .zero) }
        decoding = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Self.decoded(picture) }.value
            guard let self, !Task.isCancelled else { return }
            image = NSImage(cgImage: decoded, size: .zero)
        }
    }

    /// `image` drawn into a bitmap of its size and color space, keeping its alpha if it has one
    /// (a page with a transparent background).
    private nonisolated static func decoded(_ image: CGImage) -> CGImage {
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
