import AppKit
import CmuxNextSettings
import CmuxNextRemoteView

/// The live part of a `remote_view` tab: the pane and its stream source.
/// Development builds only (`RemoteViewAvailability`). The host `mock` is the
/// test desktop (`MockRemoteStreamSource`, VideoToolbox frames). A loopback
/// host (`local`, `localhost`, 127.0.0.0/8) streams from a real `cmux.rd/1`
/// host only when `RemoteViewDebugRdHost` is opted in by environment (an SSH
/// tunnel to a Linux `cmux-rd host`); otherwise it shows "not available".
@MainActor
final class RemoteViewPageSession {
    /// The host name that opens the test desktop.
    static let mockHost = "mock"

    #if DEBUG
    private let pane: RemoteDesktopPane
    private let source: any RemoteViewStreamSource
    /// The real host's source and how to make a new transport; nil for the mock.
    private let rd: (source: RemoteRdDebugSource, make: () -> RemoteRdStreamTransport?)?
    /// The current transport already connected once (it cannot connect again).
    private var rdUsed = false
    /// The person pressed Stop: only Reconnect starts a new session, never showing the tab again.
    private var rdStopped = false
    private var visible = false

    private init(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) {
        // The test desktop offers upstream media, so the share buttons show.
        let source = MockRemoteStreamSource(status: Self.mockStatus)
        self.source = source
        rd = nil
        pane = RemoteDesktopPane(hostName: record.host, source: source, inputSink: MockRemoteInputSink(host: source),
                                 initialMode: record.mode)
        pane.handlers.stop = { [weak source] in source?.end(.stoppedByViewer) }
        pane.handlers.reconnect = { [weak source] in
            source?.setStatus(Self.mockStatus)
            source?.requestKeyframe()
        }
        pane.handlers.close = closeTab
        pane.upstreamControl = source
    }

    /// A real host's session. Each connection gets its own transport: a
    /// hidden tab ends its session (the host stops streaming) and a shown tab
    /// or Reconnect starts a new one.
    private init(record: RemoteViewTabRecord, first: RemoteRdStreamTransport,
                 make: @escaping () -> RemoteRdStreamTransport?, closeTab: @escaping @MainActor () -> Void) {
        let rdSource = RemoteRdDebugSource(first)
        source = rdSource
        rd = (rdSource, make)
        pane = RemoteDesktopPane(hostName: record.host, source: rdSource,
                                 inputSink: RemoteRdDebugInputSink(source: rdSource), initialMode: record.mode)
        pane.handlers.stop = { [weak self] in
            self?.rdStopped = true
            rdSource.transport.stop()
        }
        pane.handlers.reconnect = { [weak self] in self?.reconnect() }
        pane.handlers.close = closeTab
        pane.upstreamControl = rdSource
    }

    /// Reconnect on an ended session: a new transport, a new subscription.
    private func reconnect() {
        rdStopped = false
        pane.stop()
        guard visible else { return }
        startRd()
    }

    /// Starts the pane on a fresh transport (the used one cannot connect
    /// again), then connects it. The pane subscribes before the connect.
    private func startRd() {
        guard let rd else { return }
        if rdUsed, let next = rd.make() { rd.source.replace(with: next) }
        rdUsed = true
        pane.start()
        rd.source.transport.connect()
    }

    private nonisolated static let mockStatus = RemoteViewStatus(
        path: .direct, rttMs: 4, state: .streaming, upstream: RemoteUpstreamStatus(offered: true)
    )

    var view: NSView { pane.view }
    var focusTarget: NSView { pane.view.focusView }

    /// `debug.remote_view` state of this session: the source, the session
    /// state and the decode counters.
    func debugState() async -> JSONValue {
        let stats = await pane.decodeStats()
        let state = pane.state
        return .object([
            "source": .string(rd == nil ? "mock" : "rd"),
            "host": .string(state.hostName),
            "state": .string(String(describing: state.sessionState)),
            "visible": .bool(visible),
            "decoded": stats.map { .number(Double($0.decoded)) } ?? .null,
            "skipped": stats.map { .number(Double($0.skipped)) } ?? .null,
            "gaps": stats.map { .number(Double($0.gaps)) } ?? .null,
            "decode_errors": stats.map { .number(Double($0.decodeErrors)) } ?? .null,
            "hardware": stats.map { .bool($0.hardware) } ?? .null,
            "upstream_offered": .bool(state.status?.upstream.offered ?? false),
        ])
    }

    /// Starts the stream while the tab is shown. Idempotent.
    func resume() {
        guard !visible else { return }
        visible = true
        guard rd != nil else {
            pane.start()
            source.requestKeyframe()
            return
        }
        // After the person's Stop the last frame and the ended card stay until Reconnect.
        // The source asks for a keyframe once the new session streams.
        if !rdStopped { startRd() }
    }

    /// Pauses the stream while the tab is hidden or closed. The last frame stays.
    func pause() {
        guard visible else { return }
        visible = false
        pane.stop()
        // A hidden or closed tab ends its rd session: the host stops streaming to it.
        rd?.source.transport.stop()
    }

    #else
    var view: NSView { NSView() }
    var focusTarget: NSView { view }
    func resume() {}
    func pause() {}
    #endif

    /// A session for `record`, or nil when this build cannot show it.
    static func make(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) -> RemoteViewPageSession? {
        #if DEBUG
        guard RemoteViewAvailability().isAvailable else { return nil }
        if record.host.lowercased() == mockHost { return RemoteViewPageSession(record: record, closeTab: closeTab) }
        guard RemoteViewTabPolicy().isLoopback(record.host), let host = RemoteViewDebugRdHost(),
              let first = host.transport(for: record) else { return nil }
        return RemoteViewPageSession(record: record, first: first, make: { host.transport(for: record) }, closeTab: closeTab)
        #else
        return nil
        #endif
    }
}
