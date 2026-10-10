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
    /// Connects the real transport on the first resume; nil for the mock.
    private let connect: (() -> Void)?
    private var visible = false

    private init(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) {
        // The test desktop offers upstream media, so the share buttons show.
        let source = MockRemoteStreamSource(status: Self.mockStatus)
        self.source = source
        connect = nil
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

    /// A real host's session. Reconnect after an end is not offered by this
    /// development path: close the tab and open it again.
    private init(record: RemoteViewTabRecord, transport: RemoteRdStreamTransport,
                 closeTab: @escaping @MainActor () -> Void) {
        source = transport
        connect = { transport.connect() }
        pane = RemoteDesktopPane(hostName: record.host, source: transport,
                                 inputSink: RemoteRdTransportInputSink(transport: transport), initialMode: record.mode)
        pane.handlers.stop = { transport.stop() }
        pane.handlers.close = closeTab
        pane.upstreamControl = transport
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
            "source": .string(connect == nil ? "mock" : "rd"),
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
        pane.start()
        // The transport ignores a second connect; a resumed session asks for a fresh picture.
        connect?()
        source.requestKeyframe()
    }

    /// Pauses the stream while the tab is hidden or closed. The last frame stays.
    func pause() {
        guard visible else { return }
        visible = false
        pane.stop()
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
              let transport = host.transport(for: record) else { return nil }
        return RemoteViewPageSession(record: record, transport: transport, closeTab: closeTab)
        #else
        return nil
        #endif
    }
}
