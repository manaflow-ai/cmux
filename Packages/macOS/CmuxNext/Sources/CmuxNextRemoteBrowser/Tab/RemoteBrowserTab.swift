public import AppKit
public import CmuxNextBrowser
public import CmuxNextInputCore
public import Foundation
public import Observation

#if DEBUG || CMUX_BENCH_HOOKS
/// A browser tab whose page runtime runs on another machine (RT1): the same
/// `BrowserTab` the chrome, the App and automation use, with the page
/// streamed by `RemoteBrowserPane`. Keys follow a local CEF tab: Command and
/// Control chords go through the app's key router first, the rest goes to
/// the remote page, and a key the page did not handle returns as the same
/// intent a local tab sends (`unhandledEscape`, `unhandledKey`).
@MainActor
@Observable
public final class RemoteBrowserTab: BrowserTab {
    public let id: BrowserTabID
    /// The runtime is Chrome (the CEF fork) on the host.
    public let engineKind: BrowserEngineKind = .cef
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage? = nil
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored public let pane: RemoteBrowserPane
    /// Where page input and commands go (the rb session); the tab owns it.
    @ObservationIgnored public let channel: any RemoteBrowserPageChannel
    /// Key downs the page has not answered yet, by input seq (bounded: the
    /// host answers only unhandled keys, so most entries are never claimed).
    @ObservationIgnored private var sentKeys: [UInt32: NSEvent] = [:]
    @ObservationIgnored private var sentOrder: [UInt32] = []
    private static let sentKeyLimit = 64
    /// The record the App builds this tab again from after a discard, for the page shown now
    /// (`BrowserStreamedPage`); unset (a tab whose host ends with it), the tab is never discarded.
    @ObservationIgnored public var wakeRecord: (@MainActor (_ page: URL?) -> URL)?
    /// A woken tab's last frame until the stream presents its first one.
    @ObservationIgnored private let wakeCover = BrowserWakeCover()

    public init(id: BrowserTabID, profile: BrowserProfileID, url: URL?, pane: RemoteBrowserPane, channel: any RemoteBrowserPageChannel) {
        self.id = id
        self.profileID = profile
        self.pane = pane
        self.channel = channel
        state = BrowserTabState(url: url)
        pane.view.eventTarget = self
        pane.onFirstFrame = { [weak self] in self?.wakeCover.remove() }
    }

    public var contentView: NSView { pane.view }

    // MARK: Input

    /// A key equivalent offered to the page view. Always consumed: either
    /// the app ran it or the remote page gets it.
    @discardableResult
    public func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if !event.modifierFlags.isDisjoint(with: [.command, .control]), let keyRouter,
           keyRouter.browserTab(self, keyEquivalent: event) == .handledByHost {
            return true
        }
        handleKey(event)
        return true
    }

    /// A key down, key up or modifier change for the page.
    public func handleKey(_ event: NSEvent) {
        let seq = channel.sendKey(event)
        guard event.type == .keyDown else { return }
        sentKeys[seq] = event
        sentOrder.append(seq)
        if sentOrder.count > Self.sentKeyLimit {
            sentKeys[sentOrder.removeFirst()] = nil
        }
    }

    public func handlePointer(_ event: NSEvent) {
        channel.sendPointer(event, at: pane.view.convert(event.locationInWindow, from: nil))
    }

    public func handlePointerFrame(_ input: PointerCoalescedInput, clickCount: Int) { // perf-hot: 2us pointer-coalesce (every frame delivery to the page)
        let location = NSPoint(x: input.latest.location.x, y: input.latest.location.y)
        channel.sendPointerFrame(input, clickCount: clickCount, at: pane.view.convert(location, from: nil))
    }

    /// The host's `rb.key_unhandled`: the page did not handle key `inputSeq`.
    public func keyUnhandled(inputSeq: UInt32) {
        guard let event = sentKeys.removeValue(forKey: inputSeq) else { return }
        sentOrder.removeAll { $0 == inputSeq }
        if event.keyCode == 53 {
            delegate?.browserTab(self, didRequest: .unhandledEscape)
        } else if let key = Self.pageKey(event) {
            delegate?.browserTab(self, didRequest: .unhandledKey(key))
        }
    }

    /// A letter with at most Shift, like Chromium's unhandled `VK_A`...`VK_Z`.
    private static func pageKey(_ event: NSEvent) -> BrowserPageKey? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let scalar = characters.lowercased().unicodeScalars.first, ("a"..."z").contains(scalar) else { return nil }
        return BrowserPageKey(character: characters, shift: event.modifierFlags.contains(.shift))
    }

    /// The host's page facts (`rb.page`): the omnibar, title and back and
    /// forward buttons follow the remote page.
    public func applyPage(url: URL?, title: String, loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        var next = state
        next.url = url ?? next.url
        next.title = title.isEmpty ? nil : title
        next.phase = loading ? .committed : .finished
        next.canGoBack = canGoBack
        next.canGoForward = canGoForward
        guard next != state else { return }
        state = next
    }

    // MARK: Failure

    /// Why the tab shows no page (the session's failure), or nil.
    public private(set) var failure: RemoteBrowserFailure?

    /// Shows `message` in the page area and a "Not Connected" title, so a
    /// refused or hostless tab is never a blank tab (cx-erey).
    public func showFailure(_ failure: RemoteBrowserFailure, message: String) {
        self.failure = failure
        wakeCover.remove()
        var next = state
        next.title = RemoteBrowserStrings.failureTitle
        next.phase = .finished
        state = next
        pane.view.showFailure(message)
    }

    // MARK: BrowserTab

    public func load(_ url: URL) { channel.load(url) }
    public func goBack() { channel.history(.back) }
    public func goForward() { channel.history(.forward) }
    public func reload() { channel.history(.reload) }
    public func stop() { channel.history(.stop) }

    public func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(contentView)
    }

    /// A hidden tab decodes nothing (Chrome stops a hidden tab's frames: `RenderWidgetHostImpl::WasHidden`
    /// in content/browser/renderer_host/render_widget_host_impl.cc): the pane pauses in the same turn
    /// and the host is told; shown again, the pane subscribes and asks for a keyframe.
    public func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        channel.setVisible(visible)
        if !visible {
            pane.pause()
        } else if failure == nil {
            pane.start()
        }
    }

    /// The page as drawn, with the stream's last frame in its video (a video layer is not drawn by
    /// `cacheDisplay`); a tab with no frame, or that failed, as drawn (its message).
    public func snapshot() async throws -> CGImage {
        if failure == nil, let picture = await pane.picture() { return picture }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    /// Scripts run through the browser host on the runtime host (RT7), not here.
    public func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        throw BrowserTabError.unsupported("remote tab")
    }

    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}

    public func close() {
        wakeCover.remove()
        pane.stop()
        channel.close()
    }
}

extension RemoteBrowserTab: RemoteBrowserEventTarget {}

extension RemoteBrowserTab: BrowserStreamedPage {
    /// Waking starts a new runtime, so the remote page's back and forward history would be lost:
    /// a tab with history is not discarded (the host keeps it while the tab is only hidden). A
    /// failed tab is not built again either.
    public var wakeAddress: URL? {
        guard failure == nil, !state.canGoBack, !state.canGoForward, let wakeRecord else { return nil }
        return wakeRecord(state.url)
    }

    /// Covers the page with its last frame until the new stream presents its first.
    @discardableResult
    public func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool {
        guard failure == nil else { return false }
        wakeCover.show(picture, decoded: decoded, in: pane.view, cap: cap, clock: clock)
        return true
    }

    public var wakeCoverCap: Duration? { BrowserWakeCover.reconnectCap }

    /// The pixels the last frame's cover draws now; nil while none covers the tab (tests, debug).
    public var wakeCoverPixels: CGImage? { wakeCover.shownPixels }

    /// The last frame covers the page now (tests, debug).
    public var showsWakeCover: Bool { wakeCover.isShown }
}
#endif
