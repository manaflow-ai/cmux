import CmuxMobileTransport
import Foundation
import Observation
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "browser-stream")

/// What a browser tab's toolbar shows and does, whether the page is a local
/// web view or a Mac browser streamed as video.
@MainActor
public protocol BrowserTabState: AnyObject {
    var url: URL? { get }
    var title: String { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    var progress: Double { get }
    var host: String { get }
    func goBack()
    func goForward()
    func reloadOrStop()
    func navigate(to text: String)
    func takeSnapshot()
}

extension BrowserTabState {
    /// Schemes the address bar hands the Mac as typed. The Mac decides what loads and says
    /// why it refuses the rest (`rb.navigate.refused`, PROTOCOL.md `browser`), so a typed
    /// `javascript:` or `chrome:` is never turned into a search.
    static var macSchemes: Set<String> {
        ["file", "data", "blob", "view-source", "about", "javascript", "chrome", "chrome-extension", "devtools", "mailto", "tel"]
    }

    /// A URL, a Mac path (`/Users/...`, a `file:` URL), a bare host, or a search.
    public static func url(for text: String) -> URL? {
        if text.isEmpty { return nil }
        if text.hasPrefix("/"), !text.hasPrefix("//") { return URL(filePath: text, directoryHint: .inferFromPath) }
        // `localhost:3000`, `mac.local:8080/x`: a host and port, on the web.
        if !text.contains(" "), let match = text.wholeMatch(of: /([A-Za-z0-9.-]+):[0-9]{1,5}(\/.*)?/),
           !macSchemes.contains(String(match.1).lowercased()) {
            return URL(string: "http://\(text)")
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme) || macSchemes.contains(scheme) { return url }
            // Another app's address (`zoommtg://...`): the Mac says it does not open those.
            if text.dropFirst(scheme.count).hasPrefix("://") { return url }
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)") { return url }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// Safari's short label (TabsKitAddress.displayLabel(for:) is the toolbar's): the host,
    /// or a local file's name, never a whole `file:` path.
    static func displayHost(_ url: URL?) -> String {
        if let url, url.isFileURL { return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
        guard let host = url?.host() else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A browser tab whose page runs on the Mac (its browser host, the CEF fork
/// the cmux-next app uses for remote tabs) and streams here as H.264 video
/// over the link's `browser` service. Touches, scrolls and typing go back as
/// `cmux.rb/1` input; `rb.page` drives the toolbar. The page is laid out at
/// this phone's size (`rb.open` / `rb.screen`).
@MainActor
@Observable
public final class StreamedBrowserModel: BrowserTabState {
    public enum Phase: Equatable, Sendable {
        case connecting
        case live
        case waiting(String)
        /// The Mac cannot stream browser tabs (its build has no browser host).
        case unavailable
    }

    /// The tab's key for its Mac browser host (a new workspace's page keeps
    /// its placeholder tab's key after the Mac names the tab).
    public let tab: String
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public var progress: Double { isLoading ? 0.5 : 1 }
    public private(set) var phase: Phase = .connecting
    /// Why the Mac did not load an address (the address bar's, or a link's inside the
    /// page): shown over the page until the next navigation or a tap.
    public private(set) var notice: String?
    /// The page's focused text field (`rb.text_input`): the keyboard rises for it.
    public private(set) var field: StreamedBrowserField?
    /// The newest numbers for the overlay: frames per second, kbit/s,
    /// capture-to-decoded latency (median of the last second), decode time.
    public private(set) var meter = Meter()
    /// The last shown picture for the grid card.
    public private(set) var snapshot: CGImageBox?
    public var host: String { Self.displayHost(url) }

    @ObservationIgnored public let decoder = BrowserVideoDecoder()
    @ObservationIgnored let wire = RemoteBrowserWire()
    @ObservationIgnored private let open: @Sendable (_ sink: any BrowserStreamSink, _ tab: String, _ url: URL?) async throws -> any BrowserStreamConnection
    @ObservationIgnored private var connection: (any BrowserStreamConnection)?
    @ObservationIgnored private var sink: Sink?
    @ObservationIgnored private var screen: RemoteBrowserWire.Screen?
    @ObservationIgnored private var appliedScreen: RemoteBrowserWire.Screen?
    @ObservationIgnored private var screenSeq = 0
    @ObservationIgnored private var welcomed = false
    /// The page is on screen and the app is active: its stream keeps the
    /// WebRTC media session beside a WireGuard link open (verify/hybrid-link.md).
    /// Pages showing this model now: a tab's new page can appear before its
    /// old one disappears (a new workspace's tab getting the Mac's id), and a
    /// page that was never shown (a neighbour laid out ahead) is not on screen.
    @ObservationIgnored private var shownBy = 0
    private var onScreen: Bool { shownBy > 0 }
    @ObservationIgnored private var appActive = true
    private var visible: Bool { onScreen && appActive }
    @ObservationIgnored private var connecting = false
    /// Opens again after the Mac stopped the page (its host limit) while no
    /// frame came in between: two, then the page waits for Reopen, so two
    /// viewers can never take one page back and forth forever.
    @ObservationIgnored private var autoReopens = 0
    /// When the page last started showing frames: the reopen count is
    /// forgiven only after it stayed live a while, so two viewers evicting
    /// each other stop after two rounds (review finding 2).
    @ObservationIgnored private var liveSince: ContinuousClock.Instant?
    static let forgiveAfter: Duration = .seconds(20)
    /// A stream opened while hidden (it said so after its `rb.open`): the
    /// directory reminds the Mac which tab is shown, so the lane goes back.
    @ObservationIgnored var openedHidden: (@MainActor () -> Void)?
    static let maxAutoReopens = 2
    /// The stream closed and only ``reopen()`` (or showing the page again)
    /// opens it: the Mac stopped the page, or another viewer took it.
    public private(set) var canReopen = false
    @ObservationIgnored private var samples: [Meter.Sample] = []
    /// A shown page that stopped (no picture after a keyframe was asked for):
    /// asks again, restarts the decoder, then opens the stream again.
    @ObservationIgnored private var watchdog = BrowserStallWatchdog()
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// How often the watchdog looks (tests replace it).
    @ObservationIgnored var watchdogTick: @Sendable () async throws -> Void = {
        try await ContinuousClock().sleep(for: .seconds(1))
    }
    /// The stream is being opened again after a stall: the page says so.
    @ObservationIgnored private var reconnecting = false
    /// Reconnects after a stall since the page last stayed live a while: after
    /// ``maxStallReconnects`` the page waits for Reopen instead of cycling.
    @ObservationIgnored private var stallReconnects = 0
    static let maxStallReconnects = 3
    static var reconnectingText: String { String(localized: "Reconnecting browser…") }
    /// A Back or Forward sent and not yet committed on the Mac (finding 5 of
    /// verify/parity-mac.md): the browser reports the old history while the page loads, so
    /// until the history moved the buttons follow the step, and a second step waits for it.
    @ObservationIgnored private var history: PendingHistory?
    /// A step tapped while another was in flight: sent once that one commits.
    @ObservationIgnored private var queuedHistory: String?
    /// A phone navigation in flight: the browser reports the old page (`about:blank` for a new
    /// tab) while it loads, which must not replace the address the person asked for.
    @ObservationIgnored private var navigating: (target: URL, from: URL?)?

    struct PendingHistory {
        var op: String
        var from: URL?
        var sawLoading = false
        var since: ContinuousClock.Instant
    }

    /// How long a sent step holds the next one back when the Mac never reports it (a page
    /// that does not load); a UI bound, not synchronization.
    static let historyHold: Duration = .seconds(2)

    public struct Meter: Equatable, Sendable {
        struct Sample: Equatable, Sendable {
            var at: UInt64
            var bytes: Int
            var latency: Int64?
            var decode: UInt32
        }

        public var fps = 0
        public var kbps = 0
        public var latencyMillis: Double?
        public var decodeMillis: Double = 0
        public var width: Int32 = 0
        public var height: Int32 = 0
        public var frames: UInt64 = 0
        /// How the frames travel: "track" (WebRTC video track) or "channel".
        public var carrier = "channel"
        public var trackDropped: UInt64 = 0
        public var trackRecovered: UInt64 = 0
    }

    /// `open` opens the `browser` service on the current link.
    public convenience init(tab: String, url: URL?, open: @escaping @Sendable (_ sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection) {
        self.init(tab: tab, url: url) { sink, _, _ in try await open(sink) }
    }

    /// `open` opens the `browser` service on the current link, at the page's
    /// current address (the Mac starts the page there when its host is gone).
    public init(tab: String, url: URL?, open: @escaping @Sendable (_ sink: any BrowserStreamSink, _ tab: String, _ url: URL?) async throws -> any BrowserStreamConnection) {
        self.tab = tab
        self.url = url
        self.open = open
        let decoder = decoder
        decoder.shown = { [weak self] shown in
            Task { @MainActor in self?.note(shown) }
        }
    }

    /// The page view's size changed (and on first layout): lays the page out
    /// at the phone's size, and connects when not yet connected.
    public func layout(points: CGSize, screenScale: Double) {
        guard points.width > 10, points.height > 10 else { return }
        let next = RemoteBrowserWire.Screen(points: points, screenScale: screenScale)
        guard next != screen else { return }
        screen = next
        sendScreen()
        // A hidden page never opens by itself: each open takes the link's
        // media lane and a Mac host (verify/redial-video.md).
        if visible { connect() }
    }

    /// Connects when there is no stream (first layout, a new link).
    public func connect() {
        guard connection == nil, !connecting, screen != nil else { return }
        connecting = true
        canReopen = false
        phase = reconnecting ? .waiting(Self.reconnectingText) : .connecting
        let sink = Sink(model: self)
        self.sink = sink
        let open = open
        let tab = tab
        // A page the Mac stopped starts again where it was, not at its first address.
        // (A cmux-mobile-host restart stops every host too: the page comes back where it was.)
        let url = url.flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        log.notice("browser \(tab, privacy: .public): open at \(url?.absoluteString ?? "-", privacy: .public)")
        // task-owner: one dial per connect; the result lands on the main actor
        Task { [weak self] in
            do {
                let connection = try await open(sink, tab, url)
                self?.opened(connection, sink: sink)
            } catch {
                log.error("browser \(tab, privacy: .public): \(String(describing: error), privacy: .public)")
                if LinkErrorText.noBrowserHost(error) {
                    self?.unavailable()
                } else {
                    self?.failed(LinkErrorText.describe(error))
                }
            }
        }
    }

    /// The page appeared or disappeared. A page shown again opens when its
    /// stream is gone (a link that dropped while it was hidden, or a page the
    /// Mac stopped).
    public func setVisible(_ visible: Bool) {
        let before = self.visible
        shownBy = visible ? shownBy + 1 : max(0, shownBy - 1)
        visibilityChanged(from: before)
    }

    /// The app went to the background or came back (a page shown when the
    /// app comes back opens if its stream dropped meanwhile).
    public func setAppActive(_ active: Bool) {
        let before = visible
        appActive = active
        visibilityChanged(from: before)
    }

    /// Whether the page is on screen now (and laid out): what opens again on
    /// a new link (``StreamedBrowserDirectory/linkChanged()``).
    public var isShown: Bool { visible && screen != nil }

    /// Tells the Mac again that this tab is shown (another tab's stream
    /// opened, and an open takes the lane).
    func reassertShown() {
        guard visible, welcomed else { return }
        send(wire.visibility(true))
    }

    /// The Mac learns which tab is shown (`rb.visibility`): the shown tab
    /// takes the link's media lane back from a hidden one (PROTOCOL.md
    /// `browser`), and a hidden page stops painting.
    private func visibilityChanged(from before: Bool) {
        guard visible != before else { return }
        connection?.setVisible(visible)
        if welcomed { send(wire.visibility(visible)) }
        updateWatch()
        // Shown again (on screen, app active) with its stream gone: open it.
        if visible { reconnect() }
    }

    /// The link changed or the page was shown: a dropped stream comes back.
    public func reconnect() {
        if connection == nil { connect() }
    }

    /// The person asked for the page again (after the Mac stopped it or
    /// another viewer took it).
    public func reopen() {
        autoReopens = 0
        stallReconnects = 0
        if connection == nil { connect() }
    }

    public func close() {
        connection?.close()
        connection = nil
        sink = nil
        updateWatch()
    }

    private func opened(_ connection: any BrowserStreamConnection, sink: Sink) {
        connecting = false
        guard self.sink === sink else {
            connection.close()
            return
        }
        self.connection = connection
        if !visible { connection.setVisible(false) }
        welcomed = false
        let decoder = decoder
        decoder.requestKeyframe = { [weak connection, weak self] in
            connection?.requestKeyframe()
            Task { @MainActor in self?.watchdog.keyframeAsked(at: .now) }
        }
        decoder.now = { [weak connection] in connection?.nowMicros() ?? 0 }
        decoder.reset()
    }

    private func unavailable() {
        connecting = false
        reconnecting = false
        sink = nil
        phase = .unavailable
    }

    private func failed(_ reason: String) {
        connecting = false
        reconnecting = false
        sink = nil
        phase = .waiting(reason)
    }

    fileprivate func received(_ json: [String: Any], from sink: Sink) {
        guard sink === self.sink else { return }
        switch json["t"] as? String {
        case "welcome":
            welcomed = true
            updateWatch()
            appliedScreen = nil
            // The host reports focus only when it changes: a new session starts with none.
            field = nil
            if let screen, let connection {
                screenSeq = 0
                try? connection.send(message: wire.open(tab: tab, viewer: "phone", screen: screen))
                // The host keeps its last viewer's visibility: a page hidden on
                // the last link (the person went to Settings to switch the
                // transport) would stay hidden, blank, under this new viewer.
                try? connection.send(message: wire.visibility(visible))
                if !visible { openedHidden?() }
            }
        case "refused", "ended":
            phase = .waiting(json["reason"] as? String ?? "The Mac ended the page")
        case "rb.text_input":
            let next = StreamedBrowserField(json: json)
            if next != field { field = next }
        case "rb.navigate.refused":
            refused(code: json["code"] as? String, reason: json["reason"] as? String)
        case "rb.page":
            guard let page = RemoteBrowserPage(json: json) else { return }
            apply(page)
        case "rb.screen_applied":
            phase = .live
        default:
            break
        }
    }

    fileprivate func closed(code: String, reason: String, from sink: Sink) {
        guard sink === self.sink else { return }
        connection = nil
        self.sink = nil
        welcomed = false
        field = nil
        liveSince = nil
        decoder.reset()
        updateWatch()
        log.info("browser \(self.tab, privacy: .public) closed: \(code, privacy: .public) \(reason, privacy: .public)")
        switch Self.afterClose(code: code, shown: visible, autoReopens: autoReopens) {
        case .reconnect:
            // The library's watchdog: the page stopped answering input, or the
            // channel stopped moving. A new stream, and the page says so.
            reconnectAfterStall()
        case .reopen:
            // The Mac stopped this page to make room (its host limit): a shown
            // page opens again at once, never a frozen frame.
            autoReopens += 1
            phase = .waiting(String(localized: "Reopening the page…"))
            connect()
        case .waitForView:
            // Opens when it is shown again (``setVisible(_:)``).
            phase = .waiting(String(localized: "Reopening the page…"))
        case .offerReopen:
            canReopen = true
            phase = .waiting(code == "replaced"
                ? String(localized: "This page is open on another device.")
                : String(localized: "Your Mac stopped this page."))
        case .waitForLink:
            phase = .waiting(code == "unavailable" || code == "forbidden" ? reason : String(localized: "Reconnecting to the Mac…"))
        }
    }

    enum AfterClose: Equatable { case reopen, reconnect, waitForView, offerReopen, waitForLink }

    /// What a closed stream does next. `evicted`: cmux-mobile-host's host limit
    /// stopped the page; `replaced`: another viewer opened the tab; `stalled`:
    /// the library's watchdog ended a stream that stopped answering; `eof`: the
    /// Mac ended it (its browser host went away) with the link up. A dropped
    /// link reopens when the next link is up (``StreamedBrowserDirectory``).
    static func afterClose(code: String, shown: Bool, autoReopens: Int) -> AfterClose {
        switch code {
        case "evicted":
            if !shown { return .waitForView }
            return autoReopens < maxAutoReopens ? .reopen : .offerReopen
        case "replaced":
            return .offerReopen
        case "stalled", "eof":
            // `eof`: the Mac ended the stream on a link that is still up (its
            // browser host exited or crashed); a new open starts a new host.
            return shown ? .reconnect : .waitForView
        default:
            return .waitForLink
        }
    }

    private func sendScreen() {
        guard welcomed, let screen, let connection else { return }
        screenSeq += 1
        try? connection.send(message: wire.screen(seq: screenSeq, screen))
    }

    private func note(_ shown: BrowserVideoDecoder.Shown) {
        if phase != .live { phase = .live }
        reconnecting = false
        watchdog.pictureShown(at: .now)
        let instant = ContinuousClock.now
        if let liveSince {
            if liveSince.duration(to: instant) >= Self.forgiveAfter {
                autoReopens = 0
                stallReconnects = 0
            }
        } else {
            liveSince = instant
        }
        let now = connection?.nowMicros() ?? 0
        samples.append(.init(at: now, bytes: shown.bytes, latency: shown.latencyMicros, decode: shown.decodeMicros))
        samples.removeAll { now &- $0.at > 1_000_000 }
        var meter = Meter()
        meter.fps = samples.count
        meter.kbps = samples.reduce(0) { $0 + $1.bytes } * 8 / 1000
        let latencies = samples.compactMap(\.latency).sorted()
        meter.latencyMillis = latencies.isEmpty ? nil : Double(latencies[latencies.count / 2]) / 1000
        meter.decodeMillis = Double(samples.map(\.decode).reduce(0, +)) / Double(max(1, samples.count)) / 1000
        meter.width = shown.width
        meter.height = shown.height
        meter.frames = self.meter.frames + 1
        if let stats = connection?.stats() {
            meter.carrier = stats.videoCarrier
            meter.trackDropped = stats.trackFramesDropped
            meter.trackRecovered = stats.trackPacketsRecovered
        }
        self.meter = meter
        if meter.frames % 30 == 1 {
            log.info("browser \(self.tab, privacy: .public): \(meter.fps) fps \(meter.kbps) kbps latency \(meter.latencyMillis ?? -1, format: .fixed(precision: 1)) ms decode \(meter.decodeMillis, format: .fixed(precision: 1)) ms \(meter.width)x\(meter.height) via \(meter.carrier, privacy: .public) dropped \(meter.trackDropped) recovered \(meter.trackRecovered)")
        }
    }

    /// The Mac's page facts, read through the step or navigation in flight.
    func apply(_ page: RemoteBrowserPage) {
        let reported = URL(string: page.url).flatMap { page.url.isEmpty ? nil : $0 }
        if let (target, from) = navigating {
            // The old page (or a new tab's about:blank) while the asked-for one loads.
            let stale = reported == nil || reported?.absoluteString == "about:blank" || reported == from
            if stale, page.loading {
                url = target
            } else {
                navigating = nil
                if let reported { url = reported }
            }
        } else if let reported {
            url = reported
        }
        title = page.title
        isLoading = page.loading
        if var step = history {
            if page.loading { step.sawLoading = true }
            let moved = reported != nil && reported != step.from
            if !page.loading, step.sawLoading || moved {
                history = nil
            } else {
                history = step
            }
        }
        if let step = history {
            // Not committed yet: a Back always leaves a page to go forward to, and the reverse.
            canGoBack = page.canGoBack || step.op == "forward"
            canGoForward = page.canGoForward || step.op == "back"
        } else {
            canGoBack = page.canGoBack
            canGoForward = page.canGoForward
            if let queued = queuedHistory {
                queuedHistory = nil
                step(queued)
            }
        }
    }

    // MARK: Toolbar

    public func goBack() { step("back") }
    public func goForward() { step("forward") }
    public func reloadOrStop() { send(wire.history(isLoading ? "stop" : "reload")) }

    /// Back or Forward. Right after another step the browser still reports the old history,
    /// so it would ignore this one: it waits until that step commits (a few hundred ms).
    private func step(_ op: String) {
        let now = ContinuousClock.now
        if let pending = history, pending.since.duration(to: now) < Self.historyHold {
            queuedHistory = op
            return
        }
        history = PendingHistory(op: op, from: url, since: now)
        if op == "back" { canGoForward = true } else { canGoBack = true }
        send(wire.history(op))
    }

    /// The Mac did not load an address: the page stays where it is (the address bar
    /// goes back to it) and the person reads why, in this phone's words when the Mac
    /// named the reason.
    func refused(code: String?, reason: String?) {
        // The refusal of the phone's own navigation: nothing loads. A link's inside the
        // page: the Mac is taking the page back, and its reports say when it is done.
        if let (_, from) = navigating {
            navigating = nil
            url = from
            isLoading = false
        }
        notice = Self.refusalText(code: code) ?? reason ?? String(localized: "Your Mac can't open this address.")
    }

    static func refusalText(code: String?) -> String? {
        switch code {
        case "file_not_shared": String(localized: "This file isn't in a folder this Mac shares with your iPhone.")
        case "file_missing": String(localized: "There's no such file in the folders this Mac shares.")
        case "script": String(localized: "Scripts can't run from your iPhone's address bar.")
        case "browser_page": String(localized: "Browser settings and internal pages can't open from your iPhone.")
        case "app_scheme": String(localized: "Links that open other apps on your Mac can't open from your iPhone.")
        case "malformed": String(localized: "This address can't be opened.")
        default: nil
        }
    }

    public func dismissNotice() { notice = nil }

    public func navigate(to text: String) {
        guard let target = Self.url(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        notice = nil
        navigating = (target, url)
        url = target
        history = nil
        queuedHistory = nil
        send(wire.navigate(target.absoluteString))
    }

    public func takeSnapshot() {
        decoder.lastPicture { [weak self] pixels in
            guard let pixels, let image = CGImageBox(pixels) else { return }
            Task { @MainActor in self?.snapshot = image }
        }
    }

    // MARK: Input (CSS pixels)

    func send(_ message: Data) {
        try? connection?.send(message: message)
    }

    func input(_ event: Data, mustDeliver: Bool = true) {
        try? connection?.send(input: event, mustDeliver: mustDeliver)
        if connection != nil { watchdog.inputSent(at: .now) }
    }

    // MARK: Watchdog

    /// Watches while the stream is open, welcomed and shown.
    private func updateWatch() {
        let watch = visible && welcomed && connection != nil
        if !watch {
            // Also after a reopen (the watchdog is restarted at the next welcome).
            watchdogTask?.cancel()
            watchdogTask = nil
            if watchdog.watching { watchdog.stop() }
        } else if !watchdog.watching {
            watchdogTask?.cancel()
            watchdog.start(at: .now)
            let tick = watchdogTick
            // task-owner: the model's watchdog; cancelled when the page stops being watched
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await tick() } catch { return }
                    guard let self else { return }
                    self.checkStall(at: .now)
                }
            }
        }
    }

    /// One look of the watchdog (tests call it with their own instants).
    func checkStall(at now: ContinuousClock.Instant) {
        switch watchdog.check(at: now) {
        case .none:
            break
        case .askKeyframe:
            connection?.requestKeyframe()
        case .restartDecoder:
            log.notice("browser \(self.tab, privacy: .public): no picture after a keyframe request; restarting the decoder")
            decoder.reset()
            connection?.requestKeyframe()
        case .reopen:
            log.notice("browser \(self.tab, privacy: .public): still no picture; opening the stream again")
            reconnectAfterStall()
        }
    }

    private func reconnectAfterStall() {
        guard stallReconnects < Self.maxStallReconnects else {
            close()
            welcomed = false
            reconnecting = false
            canReopen = true
            phase = .waiting(String(localized: "This page stopped responding."))
            return
        }
        stallReconnects += 1
        connection?.close()
        connection = nil
        sink = nil
        welcomed = false
        field = nil
        liveSince = nil
        decoder.reset()
        updateWatch()
        reconnecting = true
        connect()
    }

    // MARK: Simulator surfaces (0...1 of the simulator's screen)

    /// The simulator page's keyboard is up (its accessory bar toggles it).
    public var wantsKeyboard = false

    /// A finger on a simulator: `down`, `move` or `up` at 0...1 of its screen.
    /// Moves may be dropped under load; down and up always arrive.
    public func touch(_ kind: String, at point: CGPoint) {
        input(wire.pointer(kind, x: Double(point.x), y: Double(point.y), buttons: kind == "up" ? 0 : 1),
              mustDeliver: kind != "move")
    }

    /// Home or Lock on a simulator.
    public func pressButton(_ button: String) {
        input(wire.button(button))
    }

    /// `point` in a view of `size` showing `picture` aspect fit, as 0...1 of the
    /// picture (top-left origin), clamped to its edges. Before the first frame the
    /// picture is taken to fill the view.
    public static func normalized(_ point: CGPoint, in size: CGSize, picture: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        var drawn = CGRect(origin: .zero, size: size)
        if picture.width > 0, picture.height > 0 {
            let scale = min(size.width / picture.width, size.height / picture.height)
            let fitted = CGSize(width: picture.width * scale, height: picture.height * scale)
            drawn = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                           width: fitted.width, height: fitted.height)
        }
        let x = (point.x - drawn.minX) / drawn.width, y = (point.y - drawn.minY) / drawn.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// The CSS pixel under a point of a view of `size` points.
    func css(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        let screen = screen ?? RemoteBrowserWire.Screen(points: size, screenScale: 2)
        return (Double(point.x / max(1, size.width)) * Double(screen.cssWidth),
                Double(point.y / max(1, size.height)) * Double(screen.cssHeight))
    }
}

/// Receives on a library thread and hops to the model.
final class Sink: BrowserStreamSink, @unchecked Sendable {
    weak var model: StreamedBrowserModel?
    private let decoder: BrowserVideoDecoder

    @MainActor init(model: StreamedBrowserModel) {
        self.model = model
        decoder = model.decoder
    }

    func browserFrame(_ frame: BrowserStreamFrame) {
        guard frame.stream == 0 else { return }
        decoder.submit(frame: frame.frame, accessUnit: frame.accessUnit, keyframe: frame.keyframe,
                       receivedMicros: frame.receivedMicros, ageMicros: frame.ageMicros)
    }

    func browserMessage(_ json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        nonisolated(unsafe) let message = object
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            model.received(message, from: self)
        }
    }

    func browserClosed(code: String, reason: String) {
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            model.closed(code: code, reason: reason, from: self)
        }
    }
}

/// A decoded picture as a `CGImage` (grid cards).
public final class CGImageBox: @unchecked Sendable, Equatable {
    public let image: CGImage

    init?(_ pixels: CVPixelBuffer) {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return nil }
        self.image = image
    }

    public static func == (lhs: CGImageBox, rhs: CGImageBox) -> Bool { lhs === rhs }
}

enum LinkErrorText {
    /// The Mac has no browser host: cmux-mobile-host's `no_browser_host`, or an older
    /// Mac's "this build has no browser host" (never shown as is).
    static func noBrowserHost(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return false }
        // `no_surface_host`: the Mac streams no simulators (an older Mac refuses `surface` as unknown).
        if ["no_surface_host", "unknown_service"].contains(error.code) { return true }
        return error.code == "no_browser_host" || error.message.localizedCaseInsensitiveContains("no browser host")
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LinkError {
            if error.code == "no-link" { return "Not connected to the Mac" }
            // An older Mac's scheme list (before the shared-folder rules): say what to do.
            if error.code == "forbidden", error.message == "only http, https and about:blank load" {
                return String(localized: "Update cmux on your Mac to open this page on your iPhone.")
            }
            return error.message.isEmpty ? error.code : error.message
        }
        return String(describing: error)
    }
}

import VideoToolbox
