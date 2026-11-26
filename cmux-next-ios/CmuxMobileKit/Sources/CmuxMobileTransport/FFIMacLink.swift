#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import Foundation

/// Dials Macs through the Rust cmux-mobile-link core (WebRTC or WireGuard).
public struct FFIMacLinkDialer: MacLinkDialer {
    /// A dev build's `X-Cmux-Build-Space` value (`dev:<slug>`), nil to send none, or the refusal of a
    /// misconfigured dev build (`CMUXBuildSpaceError`), which dials nothing. The Rust core puts the
    /// value on every cmux-mobile-api request and the signaling upgrade it makes.
    let buildSpace: Result<String?, any Error>

    public init(buildSpace: Result<String?, any Error>) {
        self.buildSpace = buildSpace
    }

    /// The build space is process state in the Rust core, set before each call that reaches the
    /// service, like the keepalive setting. Throws, setting nothing, for a misconfigured dev build.
    private func applyBuildSpaceToCore() throws {
        setBuildSpace(value: try buildSpace.get())
    }

    /// Settings → Transport → Direct on Wi-Fi (`CmuxMobilePreferences.Key.lanDirect`, the same
    /// `UserDefaults` key; on when unset). On, hands the Rust core a folder under Application Support
    /// (created if missing) where it keeps the phone's LAN key and per-Mac enrollment, which turns the
    /// direct path on; off, or if the folder cannot be made, passes nil and `connect` uses the relay as
    /// before. Called at each dial, like the keepalive setting.
    static func applyLanDirectToCore(_ defaults: UserDefaults = .standard) {
        let key = "cmuxMobile.settings.lanDirect"
        guard defaults.object(forKey: key) == nil || defaults.bool(forKey: key),
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
              case let dir = support.appendingPathComponent("lan-direct", isDirectory: true),
              (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else {
            setLanMemoryDir(dir: nil)
            return
        }
        setLanMemoryDir(dir: dir.path)
    }

    /// Settings → Transport → Ultra mode (`CmuxMobilePreferences.Key.ultra`, the same
    /// `UserDefaults` key; this module does not link CmuxMobileDesign): "off", "auto" or
    /// "always". Rust reads anything else as Auto, and caps Auto on cellular (`set_cellular_path`).
    static func ultra(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "cmuxMobile.settings.ultra") ?? "auto"
    }

    public func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let observer = StateObserver()
        // Macs nearby are browsed for once a dial has run (linked or not), never at launch: the Local
        // Network prompt then never covers the first frame. The core races a nearby Mac's hub with
        // the service from the next dial on, and a declined prompt costs nothing.
        defer { LocalLinkBrowser.shared.start() }
        // Settings → Transport → Align Keepalives, read at each dial like Ultra mode.
        KeepaliveBeat.applySettingToCore()
        Self.applyLanDirectToCore()
        try applyBuildSpaceToCore()
        do {
            let handle = try await connectWithOptions(
                baseUrl: endpoint.baseURL.absoluteString,
                token: accessToken,
                teamId: endpoint.teamID,
                deviceId: endpoint.deviceID,
                macDeviceId: endpoint.macDeviceID,
                transport: transport.ffi,
                options: ConnectOptions(relayOnly: endpoint.relayOnly, blockUdp: endpoint.blockUDP,
                                        proxyOnly: endpoint.proxyOnly, dropWireguard: endpoint.dropWireGuard,
                                        forceRelay: endpoint.forceRelay,
                                        noVideoLane: endpoint.browserVideoOnChannel,
                                        ultra: Self.ultra()),
                observer: observer
            )
            return FFIMacLink(handle: handle, transport: transport, observer: observer)
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    public func prewarm(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] {
        // The signaling socket opened here reads the setting at its ticks.
        KeepaliveBeat.applySettingToCore()
        Self.applyLanDirectToCore()
        guard (try? applyBuildSpaceToCore()) != nil else { return [] }
        return await CmuxMobileLinkFFI.prewarm(baseUrl: baseURL.absoluteString, token: accessToken, teamId: teamID, deviceId: deviceID)
            .map { ($0.name, $0.millis) }
    }

    public func resetWarmState() async {
        await CmuxMobileLinkFFI.resetWarmState()
    }

    public func networkChanged(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] {
        guard (try? applyBuildSpaceToCore()) != nil else { return [] }
        return await CmuxMobileLinkFFI.networkChanged(baseUrl: baseURL.absoluteString, token: accessToken, teamId: teamID, deviceId: deviceID)
            .map { ($0.name, $0.millis) }
    }
}

final class FFIMacLink: TimedMacLink, @unchecked Sendable {
    let transport: TransportKind
    let states: AsyncStream<LinkState>
    private let handle: LinkHandle
    private let observer: StateObserver

    init(handle: LinkHandle, transport: TransportKind, observer: StateObserver) {
        self.handle = handle
        self.transport = transport
        self.observer = observer
        self.states = observer.stream
        observer.yield(.connected(transport, handle.path().kind, rttMillis: nil))
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        do {
            return FFIChannel(handle: try await handle.openChannel(service: service, argsJson: json))
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    func openChannel(service: String, argsJSON: String) async throws -> any LinkChannel {
        do {
            return FFIChannel(handle: try await handle.openChannel(service: service, argsJson: argsJSON))
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        do {
            return FFIChannel(handle: try await handle.openInputChannel(service: service, argsJson: json))
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    var connectedPath: LinkPathKind? { handle.path().kind }

    var peerScope: String { handle.peerScope() }

    var tunnelKeys: TunnelKeys? {
        let keys = handle.tunnelKeys()
        return keys.count == 2 ? TunnelKeys(dialer: keys[0], answerer: keys[1]) : nil
    }

    var receivedAgo: Duration? { .milliseconds(handle.receivedAgoMs()) }

    var trafficAgo: Duration? { .milliseconds(handle.trafficAgoMs()) }

    var timings: [(String, Double)] {
        handle.timings().map { ($0.name, $0.millis) }
    }

    func ping() async throws -> UInt32 {
        do { return try await handle.ping() } catch let error as CmuxMobileError { throw error.linkError }
    }

    func probe(timeout: Duration) async throws -> UInt32? {
        let millis = UInt32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        do { return try await handle.probe(timeoutMs: millis) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func probeTimeout(floor: Duration) -> Duration {
        let millis = UInt32(clamping: floor.components.seconds * 1000 + floor.components.attoseconds / 1_000_000_000_000_000)
        return .milliseconds(handle.probeTimeoutMs(floorMs: millis))
    }

    func setForegroundProbe(_ on: Bool) {
        handle.setForegroundProbe(on: on)
    }

    func prewake() {
        _ = handle.prewake()
    }

    func close() async {
        handle.close()
    }
}

extension FFIMacLink: ParkableMacLink {
    var resumeHedge: Duration? { .milliseconds(handle.resumeHedgeMs()) }

    func park(hold: Duration, timeout: Duration) async -> Bool {
        (try? await handle.park(holdMs: Self.millis(hold), timeoutMs: Self.millis(timeout))) ?? false
    }

    func resumeParked() -> Bool {
        handle.resume()
    }

    private static func millis(_ duration: Duration) -> UInt32 {
        UInt32(clamping: duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

extension FFIMacLink: NetworkChangeProbing {
    func networkChangeProbe(roam: Bool, windowMillis: UInt32) async -> String {
        await handle.debugNetworkChangeProbe(roam: roam, windowMs: windowMillis)
    }
}

extension FFIMacLink: BrowserStreamOpening {
    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        var args = ["tab": tab]
        if let url { args["url"] = url }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        do {
            return FFIBrowserStream(
                handle: try await handle.openBrowser(argsJson: json, observer: BrowserObserverBridge(sink: sink)),
                transport: transport
            )
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    func warmMedia() {
        handle.warmMedia()
    }

    func openLocalhost(port: UInt16) async throws -> any LinkChannel {
        try await openChannel(service: "localhost", args: ["port": String(port)])
    }

    func openSurface(tab: String, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["tab": tab]), as: UTF8.self)
        do {
            return FFIBrowserStream(
                handle: try await handle.openSurface(argsJson: json, observer: BrowserObserverBridge(sink: sink)),
                transport: transport
            )
        } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }
}

final class BrowserObserverBridge: BrowserObserver, @unchecked Sendable {
    private let sink: any BrowserStreamSink

    init(sink: any BrowserStreamSink) { self.sink = sink }

    func onFrame(frame: BrowserFrame) {
        sink.browserFrame(BrowserStreamFrame(
            stream: frame.stream, frame: frame.frame, keyframe: frame.keyframe, accessUnit: frame.accessUnit,
            captureMicros: frame.captureUs, receivedMicros: frame.receivedUs, ageMicros: frame.ageUs))
    }

    func onMessage(json: String) { sink.browserMessage(Data(json.utf8)) }

    func onClosed(code: String, reason: String) { sink.browserClosed(code: code, reason: reason) }
}

final class FFIBrowserStream: BrowserStreamConnection, @unchecked Sendable {
    private let handle: BrowserStream
    /// The link's transport, which names the media lane's carrier.
    private let transport: TransportKind

    init(handle: BrowserStream, transport: TransportKind) {
        self.handle = handle
        self.transport = transport
    }

    func send(message: Data) throws {
        do { try handle.sendMessage(json: String(decoding: message, as: UTF8.self)) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func send(input: Data, mustDeliver: Bool) throws {
        do {
            try handle.sendInput(json: String(decoding: input, as: UTF8.self), mustDeliver: mustDeliver)
        } catch let error as CmuxMobileError { throw error.linkError }
    }

    func requestKeyframe() { handle.requestKeyframe() }
    func setVisible(_ visible: Bool) { handle.setVisible(visible: visible) }
    func noteDecode(micros: UInt32) { handle.noteDecode(decodeUs: micros) }
    func nowMicros() -> UInt64 { handle.nowUs() }
    func close() { handle.close() }

    func stats() -> BrowserStreamStats {
        let raw = handle.stats()
        var stats = BrowserStreamStats()
        stats.frames = raw.frames
        stats.keyframes = raw.keyframes
        stats.bytes = raw.bytes
        stats.framesLost = raw.framesLost
        stats.clockOffsetMicros = raw.clockOffsetUs
        stats.clockRTTMicros = raw.clockRttUs
        stats.videoTrack = raw.videoTrack
        stats.videoCarrier = BrowserStreamStats.carrier(library: raw.videoCarrier, videoTrack: raw.videoTrack,
                                                        transport: transport)
        stats.trackFramesDropped = raw.trackFramesDropped
        stats.trackPacketsRecovered = raw.trackPacketsRecovered
        return stats
    }
}

final class FFIChannel: LinkChannel, @unchecked Sendable {
    private let handle: ChannelHandle
    let id: UInt32
    private let closeLock = NSLock()
    private var closeInfo: LinkError?
    var closedBy: LinkError? { closeLock.withLock { closeInfo } }
    var sentBytes: UInt64? { handle.sentBytes() }

    init(handle: ChannelHandle) {
        self.handle = handle
        self.id = handle.id()
    }

    func send(_ data: Data) async throws {
        do { try await handle.send(data: data) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func observedWrite(_ data: Data) -> LinkWrite {
        let watch = ChannelWriteWatch()
        return LinkWrite(send: { [handle] in
            do { try await handle.sendObserved(data: data, watch: watch) }
            catch let error as CmuxMobileError { throw error.linkError }
        }, takeProgress: { watch.takeProgress() }, cancel: { watch.cancel() })
    }

    func receive() async throws -> Data? {
        switch await handle.recv() {
        case .data(let bytes): return bytes
        case .closed(let code, let reason):
            closeLock.withLock { closeInfo = LinkError(code: code, message: reason) }
            return nil
        }
    }

    func close(code: String, reason: String) async {
        await handle.close(code: code, reason: reason)
    }
}

/// Bridges Rust link events into `LinkState`.
final class StateObserver: LinkObserver, @unchecked Sendable {
    let stream: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    private let lock = NSLock()
    private var current: (TransportKind, LinkPathKind)?

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func yield(_ state: LinkState) {
        continuation.yield(state)
    }

    func onEvent(event: LinkEvent) {
        lock.withLock {
            switch event {
            case .connecting(let transport):
                continuation.yield(.connecting(transport.kind))
            case .connected(let transport, let path):
                current = (transport.kind, path.kind)
                continuation.yield(.connected(transport.kind, path.kind, rttMillis: nil))
            case .pathChanged(let path):
                if let (transport, _) = current {
                    current = (transport, path.kind)
                    continuation.yield(.connected(transport, path.kind, rttMillis: nil))
                }
            case .rtt(let millis):
                if let (transport, path) = current {
                    continuation.yield(.connected(transport, path, rttMillis: millis))
                }
            case .media(let state):
                continuation.yield(.media(state.videoMedia))
            case .disconnected(let reason):
                continuation.yield(.disconnected(reason: reason))
            case .suspect(let silentMillis):
                continuation.yield(.suspect(silentMillis: silentMillis))
            }
        }
    }
}

extension TransportKind {
    var ffi: Transport { self == .webRTC ? .webRtc : .wireGuard }
}

extension Transport {
    var kind: TransportKind { self == .webRtc ? .webRTC : .wireGuard }
}

extension LinkPath {
    var kind: LinkPathKind {
        switch self {
        case .direct: .direct
        case .turn: .turn
        case .turnTls: .turnTLS
        case .httpsRelay: .httpsRelay
        case .noPath: .noPath
        }
    }
}

extension MediaState {
    var videoMedia: VideoMediaState {
        switch self {
        case .off: .off
        case .connecting: .connecting
        case .up(let path, let rtt): .up(path.kind, rttMillis: rtt)
        case .failed(let reason, _): .failed(reason: reason)
        }
    }
}

extension CmuxMobileError {
    var linkError: LinkError {
        switch self {
        case .InvalidArgument(let message): LinkError(code: "invalid_argument", message: message)
        case .Signaling(let message): LinkError(code: "signaling", message: message)
        case .Refused(let code, let message): LinkError(code: code, message: message)
        case .Timeout: LinkError(code: "timeout", message: "link request timed out")
        case .Transport(let message): LinkError(code: "transport", message: message)
        case .Closed(let message): LinkError(code: "closed", message: message)
        }
    }
}
#endif
