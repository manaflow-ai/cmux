public import AppKit
public import CmuxNextCompat
public import CmuxNextRemoteView
public import CmuxNextSettings
public import CmuxVNC

/// The live part of a `remote_view` tab: the pane and its stream source.
/// Development builds only (`RemoteViewAvailability`). The host `mock` is the
/// test desktop (`MockRemoteStreamSource`, VideoToolbox frames). A loopback
/// host (`local`, `localhost`, 127.0.0.0/8) streams from a real `cmux.rd/1`
/// host only when `RemoteViewDebugRdHost` is opted in by environment (an SSH
/// tunnel to a Linux `cmux-rd host`); otherwise it shows "not available".
/// A record with `via=vnc` streams from an RFB compatibility host through
/// `RemoteVNCSession` (`mock` is then the loopback VNC demo desktop).
@MainActor
public final class RemoteViewPageSession {
    /// The host name that opens the test desktop.
    public static let mockHost = "mock"

    /// A byte stream to a Cloud machine's websockify port (6901) over the app's Cloud tunnel.
    public nonisolated struct CloudDesktopStream: Sendable {
        /// The next bytes, nil at the end of the stream.
        public let read: @Sendable () async throws -> Data?
        public let write: @Sendable (Data) async throws -> Void
        public let close: @Sendable () -> Void

        public init(read: @escaping @Sendable () async throws -> Data?, write: @escaping @Sendable (Data) async throws -> Void,
                    close: @escaping @Sendable () -> Void) {
            self.read = read
            self.write = write
            self.close = close
        }
    }

    /// How to open Cloud machine `machine`'s desktop stream (once per session), or nil when the
    /// app cannot reach it over its Cloud tunnel (signed out, no address).
    public typealias CloudDesktopTransport = @MainActor (_ machine: String) -> (@Sendable () async throws -> CloudDesktopStream)?

    /// The `cmux-rd` transports of Cloud machine `machine`'s desktop (a new one per session: a
    /// used transport cannot connect again), or nil when the app has no route or token for it.
    public typealias CloudRdTransport = @MainActor (_ machine: String, _ control: Bool) -> (@MainActor () -> RemoteRdStreamTransport?)?

    /// The machine's VNC server as websockify serves it next to noVNC, over `open`'s stream.
    nonisolated static func cloudRFBTransport(_ open: @escaping @Sendable () async throws -> CloudDesktopStream) -> any RFBTransport {
        WebSocketRFBTransport(host: "localhost:6901") { CloudDesktopByteStream(try await open()) }
    }

    #if DEBUG
    private let pane: RemoteDesktopPane
    private let source: any RemoteViewStreamSource
    /// The real host's source and how to make a new transport; nil for the mock.
    private let rd: (source: RemoteRdDebugSource, make: @MainActor () -> RemoteRdStreamTransport?)?
    /// The VNC compatibility session; nil for the mock and rd hosts.
    private let vnc: RemoteVNCSession?
    /// The current transport already connected once (it cannot connect again).
    private var rdUsed = false
    /// The person pressed Stop: only Reconnect starts a new session, never showing the tab again.
    private var rdStopped = false
    private var visible = false
    /// A Cloud desktop (over the app's Cloud tunnel) keeps its session through a short hide, so
    /// switching away and back shows the live picture instead of reconnecting.
    private let keepsSessionWhenHidden: Bool
    /// The session's end after the hide grace; nil while shown or once it ended.
    private var hiddenStop: Task<Void, Never>?
    /// The session is still running from before the last hide.
    private var liveWhileHidden = false
    /// How long a hidden Cloud desktop keeps its session.
    static let cloudHideGrace: Duration = .seconds(120)

    private init(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) {
        // The test desktop offers upstream media, so the share buttons show.
        let source = MockRemoteStreamSource(status: Self.mockStatus)
        self.source = source
        rd = nil
        vnc = nil
        keepsSessionWhenHidden = false
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
                 make: @escaping @MainActor () -> RemoteRdStreamTransport?, closeTab: @escaping @MainActor () -> Void,
                 displayName: String? = nil) {
        let rdSource = RemoteRdDebugSource(first)
        source = rdSource
        rd = (rdSource, make)
        vnc = nil
        keepsSessionWhenHidden = record.cloudDesktop
        pane = RemoteDesktopPane(hostName: displayName ?? record.host, source: rdSource,
                                 inputSink: RemoteRdDebugInputSink(source: rdSource), initialMode: record.mode,
                                 viaCloudTunnel: record.cloudDesktop)
        pane.handlers.stop = { [weak self] in
            self?.rdStopped = true
            rdSource.transport.stop()
        }
        pane.handlers.reconnect = { [weak self] in self?.reconnect() }
        pane.handlers.close = closeTab
        pane.upstreamControl = rdSource
    }

    /// An RFB compatibility host: decoded frames, fitted to the pane, on the
    /// layer-contents presenter (the Metal presenter is for YUV video).
    private convenience init(vncRecord record: RemoteViewTabRecord, port: UInt16, closeTab: @escaping @MainActor () -> Void) {
        self.init(vnc: RemoteVNCSession(record: record, port: port, demoHost: Self.mockHost), closeTab: closeTab)
    }

    private init(vnc: RemoteVNCSession, closeTab: @escaping @MainActor () -> Void, displayName: String? = nil) {
        let record = vnc.record
        self.vnc = vnc
        source = vnc.source
        rd = nil
        keepsSessionWhenHidden = record.cloudDesktop
        pane = RemoteDesktopPane(hostName: displayName ?? record.host, source: vnc.source, inputSink: RemoteVNCInputSink(source: vnc.source),
                                 presenter: .layerContents, initialMode: record.mode, scaling: .fit,
                                 viaCloudTunnel: record.cloudDesktop)
        pane.handlers.stop = { [weak self] in
            self?.rdStopped = true
            vnc.stop()
        }
        pane.handlers.reconnect = { [weak self] in
            self?.rdStopped = false
            vnc.reconnect(in: self?.pane.view.window)
        }
        pane.handlers.close = { [weak vnc] in
            vnc?.close()
            closeTab()
        }
    }

    /// Gives a VNC session the app's one guard of the Keychain UI switch, which reads and saves its
    /// sign-in. The page tab calls it once, right after ``make(record:closeTab:cloudTransport:cloudRd:displayName:)``
    /// and before the first connect; a session without it reads no saved sign-in.
    public func useLoginKeychain(_ loginKeychain: LoginKeychain) {
        vnc?.loginKeychain = loginKeychain
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

    public var view: NSView { pane.view }
    public var focusTarget: NSView { pane.view.focusView }

    /// `debug.remote_view` state of this session: the source, the session
    /// state and the decode counters.
    public func debugState() async -> JSONValue {
        let stats = await pane.decodeStats()
        let state = pane.state
        let vncInfo = vnc?.source.serverInfo
        return .object([
            "source": .string(vnc != nil ? "vnc" : (rd == nil ? "mock" : "rd")),
            "vnc_server": vncInfo.map { .string("\($0.name) \($0.width)x\($0.height) security \($0.securityType)") } ?? .null,
            "frame_pixels": .string("\(Int(pane.framePixels.width))x\(Int(pane.framePixels.height))"),
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

    /// Starts the stream while the tab is shown. Idempotent. A Cloud desktop shown again within
    /// its hide grace only resumes drawing: its session never stopped.
    public func resume() {
        guard !visible else { return }
        visible = true
        hiddenStop?.cancel()
        hiddenStop = nil
        if liveWhileHidden {
            liveWhileHidden = false
            pane.start()
            return
        }
        if let vnc {
            pane.start()
            if !rdStopped { vnc.connect() }
            return
        }
        guard rd != nil else {
            pane.start()
            source.requestKeyframe()
            return
        }
        // After the person's Stop the last frame and the ended card stay until Reconnect.
        // The source asks for a keyframe once the new session streams.
        if !rdStopped { startRd() }
    }

    /// Pauses the stream while the tab is hidden or closed. The last frame stays. A Cloud desktop
    /// keeps its session for `cloudHideGrace` first (a quick switch away and back costs nothing);
    /// `close` ends it at once.
    public func pause() {
        guard visible else { return }
        visible = false
        pane.stop()
        if keepsSessionWhenHidden, !rdStopped {
            liveWhileHidden = true
            hiddenStop = Task { [weak self] in
                // wakeup-allow: one cancellable deadline per hide; showing the tab again cancels it.
                try? await Task.sleep(for: Self.cloudHideGrace)
                guard !Task.isCancelled else { return }
                self?.endHiddenSession()
            }
            return
        }
        endHiddenSession()
    }

    /// The tab closed: drawing and the session end now, with no hide grace.
    public func end() {
        pause()
        hiddenStop?.cancel()
        endHiddenSession()
    }

    /// Ends the session of a hidden tab: the host stops streaming to it.
    private func endHiddenSession() {
        hiddenStop = nil
        liveWhileHidden = false
        vnc?.stop()
        // A hidden or closed tab ends its rd session: the host stops streaming to it.
        rd?.source.transport.stop()
    }

    #else
    public var view: NSView { NSView() }
    public var focusTarget: NSView { view }
    public func resume() {}
    public func pause() {}
    public func end() {}
    public func useLoginKeychain(_ loginKeychain: LoginKeychain) {}
    #endif

    /// A session for `record`, or nil when this build cannot show it. `cloudTransport` makes the
    /// transports of a Cloud machine's desktop (`via=cloud`) over the app's Cloud tunnel; nil, or
    /// nil for that machine (signed out, no address), shows "not available".
    public static func make(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void,
                            cloudTransport: CloudDesktopTransport? = nil, cloudRd: CloudRdTransport? = nil,
                            displayName: String? = nil) -> RemoteViewPageSession? {
        #if DEBUG
        guard RemoteViewAvailability().isAvailable else { return nil }
        if record.cloudRd {
            guard let make = cloudRd?(record.host, record.mode == .control), let first = make() else { return nil }
            return RemoteViewPageSession(record: record, first: first, make: make, closeTab: closeTab, displayName: displayName)
        }
        if record.cloudDesktop {
            guard let open = cloudTransport?(record.host) else { return nil }
            let vnc = RemoteVNCSession(cloudRecord: record, makeTransport: { cloudRFBTransport(open) })
            return RemoteViewPageSession(vnc: vnc, closeTab: closeTab, displayName: displayName)
        }
        if let port = record.vncPort { return RemoteViewPageSession(vncRecord: record, port: port, closeTab: closeTab) }
        if record.host.lowercased() == mockHost { return RemoteViewPageSession(record: record, closeTab: closeTab) }
        guard RemoteViewTabPolicy().isLoopback(record.host), let host = RemoteViewDebugRdHost(),
              let first = host.transport(for: record) else { return nil }
        return RemoteViewPageSession(record: record, first: first, make: { host.transport(for: record) }, closeTab: closeTab)
        #else
        return nil
        #endif
    }
}

/// `RemoteViewPageSession.CloudDesktopStream` as the RFB client's byte stream.
private nonisolated struct CloudDesktopByteStream: RFBByteStream {
    let stream: RemoteViewPageSession.CloudDesktopStream

    init(_ stream: RemoteViewPageSession.CloudDesktopStream) {
        self.stream = stream
    }

    /// Each read waits for the tunnel's next event; the WebSocket layer above reads again until
    /// it holds a whole frame.
    func read() async throws -> [UInt8] {
        guard let data = try await stream.read() else { throw RFBError.connectionClosed }
        return [UInt8](data)
    }

    func write(_ bytes: [UInt8]) async throws {
        try await stream.write(Data(bytes))
    }

    func close() {
        stream.close()
    }
}
