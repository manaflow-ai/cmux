import AppKit
public import CmuxBrowserStream
public import CmuxMobileHost
public import Foundation

/// One phone on one Mac tab: pixels from the tab's window through
/// ScreenCaptureKit and VideoToolbox (`CapturedVideoSource`), page state and
/// geometry from the tab, input as DevTools `Input` commands
/// (`BrowserCDPInput`), navigation through the tab. The page owner (the tab)
/// applies everything.
public actor TabBrowserPageAttachment: BrowserPageAttachment {
    public nonisolated let video: any BrowserVideoSource
    private let tab: any MobileBrowserTab
    private let capture: ScreenCaptureFrameCapture
    private var placement: MobileBrowserPlacement
    private var watcher: Task<Void, Never>?
    private var sinks: [UUID: AsyncStream<BrowserPageEvent>.Continuation] = [:]
    private var lastPage: RbPage?
    private var lastGeometry: BrowserPageGeometry?
    private var detached = false

    static func start(tab: any MobileBrowserTab, placement: MobileBrowserPlacement) async -> TabBrowserPageAttachment {
        let attachment = TabBrowserPageAttachment(tab: tab, placement: placement)
        await attachment.watch()
        return attachment
    }

    private init(tab: any MobileBrowserTab, placement: MobileBrowserPlacement) {
        self.tab = tab
        self.placement = placement
        let capture = ScreenCaptureFrameCapture(windowID: placement.windowID, contentRect: placement.rect)
        self.capture = capture
        video = CapturedVideoSource(capture: capture, encoder: VideoToolboxH264Encoder())
    }

    public var geometry: BrowserPageGeometry {
        get async {
            let tab = tab
            return await MainActor.run { tab.geometry }
        }
    }

    public func events() async -> AsyncStream<BrowserPageEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserPageEvent.self, bufferingPolicy: .bufferingNewest(64))
        guard !detached else {
            continuation.yield(.closed(reason: "detached"))
            continuation.finish()
            return stream
        }
        let tab = tab
        let page = await MainActor.run { tab.page }
        lastPage = page
        continuation.yield(.page(page))
        let id = UUID()
        sinks[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropSink(id) } }
        return stream
    }

    public func apply(_ input: RbInputEvent) async {
        let tab = tab
        for call in BrowserCDPInput.calls(for: input) {
            let params = call.foundationParams
            try? await tab.devTools(method: call.method, params: params)
        }
    }

    public func load(_ url: URL) async throws {
        let tab = tab
        await MainActor.run { tab.load(url) }
    }

    public func history(_ op: RbHistoryOp) async {
        let tab = tab
        await MainActor.run {
            switch op {
            case .back: tab.goBack()
            case .forward: tab.goForward()
            case .reload, .reloadNoCache: tab.reload()
            case .stop: tab.stopLoading()
            }
        }
    }

    /// The phone's text goes on the general pasteboard right before its paste.
    public func pasteboard(_ items: [RbClipboardItem]) async {
        guard let text = items.first(where: { $0.mime.hasPrefix("text/plain") && !$0.base64 })?.data else { return }
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// The Mac owns the page's visibility; a hidden phone only stops reading frames.
    public func setVisible(_ visible: Bool) async {}

    public func detach() async {
        guard !detached else { return }
        detached = true
        watcher?.cancel()
        watcher = nil
        await capture.stop()
        for sink in sinks.values { sink.finish() }
        sinks = [:]
    }

    // MARK: Private

    private func watch() async {
        let tab = tab
        let changes = await MainActor.run { tab.changes() }
        watcher = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                let now = await MainActor.run { (tab.page, tab.geometry, tab.placement) }
                await self.changed(page: now.0, geometry: now.1, placement: now.2)
            }
            await self?.closed()
        }
    }

    private func changed(page: RbPage, geometry: BrowserPageGeometry, placement: MobileBrowserPlacement?) async {
        if page != lastPage {
            lastPage = page
            emit(.page(page))
        }
        if geometry != lastGeometry {
            lastGeometry = geometry
            emit(.geometry(geometry))
        }
        if let placement, placement.rect != self.placement.rect, placement.windowID == self.placement.windowID {
            self.placement = placement
            try? await capture.updateRect(placement.rect)
        }
    }

    private func closed() {
        emit(.closed(reason: "closed"))
        for sink in sinks.values { sink.finish() }
        sinks = [:]
    }

    private func emit(_ event: BrowserPageEvent) {
        for sink in sinks.values { sink.yield(event) }
    }

    private func dropSink(_ id: UUID) { sinks[id] = nil }
}
