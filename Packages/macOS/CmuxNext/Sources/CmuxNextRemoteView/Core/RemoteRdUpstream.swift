import CCmuxRdFFI
public import Foundation

/// The viewer's sender for one upstream media stream (microphone, camera or
/// screen share) of a `cmux.rd/1` session, implemented by the shared Rust
/// core (cmux-rd-ffi `CmuxRdUpstream`, rd change C4b): encoded frames in,
/// `UpMedia` datagrams out, the host's upstream feedback in.
///
/// Consent (coordinator condition): a sender starts without consent and
/// sends nothing until `RemoteUpstreamConsent` grants its kind after an
/// explicit user action in this session. Consent ends with the instance.
/// `RemoteUpstreamConsent` creates senders, only when welcome lists
/// `up_media` and the host answered `stream_opened` for the stream. No I/O,
/// threads or timers inside; not thread-safe: one actor owns an instance,
/// like `RemoteRdCore`.
public nonisolated final class RemoteRdUpstream {
    public let kind: RemoteUpstreamKind
    public let stream: UInt16
    private let handle: OpaquePointer

    /// Only `RemoteUpstreamConsent` (and tests) create senders. Nil when the
    /// core refuses the parameters (`maxDatagram` outside 64...9000) or
    /// cannot allocate. Opus audio carries its own FEC, so the microphone
    /// sender uses none. `path`: a `CMUX_RD_PATH_*` class.
    init?(
        carrier: RemoteRdCore.Carrier,
        stream: UInt16,
        kind: RemoteUpstreamKind,
        maxDatagram: UInt32 = 1152,
        path: UInt32 = UInt32(CMUX_RD_PATH_VIA_CLOUD_REGION)
    ) {
        guard let handle = cmux_rd_upstream_new(
            carrier.raw, stream, kind.raw, maxDatagram, path, 0, 0, 0, kind != .microphone
        ) else { return nil }
        self.kind = kind
        self.stream = stream
        self.handle = handle
    }

    deinit {
        cmux_rd_upstream_free(handle)
    }

    /// The path class of a loopback or LAN host (`CMUX_RD_PATH_DIRECT_LAN`).
    static let directLANPath = UInt32(CMUX_RD_PATH_DIRECT_LAN)

    /// Grants or revokes consent for this sender's kind. Only
    /// `RemoteUpstreamConsent` calls this; revoking drops untaken datagrams.
    func setConsent(_ granted: Bool) {
        _ = cmux_rd_upstream_set_consent(handle, kind.raw, granted)
    }

    /// Sends one encoded frame; returns the datagrams queued (0 when the
    /// pacer dropped it). Throws `.consent` without consent.
    @discardableResult
    public func send(frame: Data, captureMicros: UInt64, independent: Bool, nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        let code = frame.withUnsafeBytes { raw in
            cmux_rd_upstream_send_frame(
                handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                captureMicros, independent, nowMicros
            )
        }
        return try RemoteRdCoreError.check(code)
    }

    /// Offers a datagram from the host. Returns false when it is not this
    /// stream's feedback (offer it to the next sender).
    @discardableResult
    public func receive(datagram: Data, nowMicros: UInt64) throws(RemoteRdCoreError) -> Bool {
        let code = datagram.withUnsafeBytes { raw in
            cmux_rd_upstream_on_datagram(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, nowMicros)
        }
        if code == CMUX_RD_ERR_STREAM { return false }
        _ = try RemoteRdCoreError.check(code)
        return true
    }

    /// Every queued datagram, framed for the carrier, in send order.
    public func datagrams() throws(RemoteRdCoreError) -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        while let datagram = try popDatagram(into: &buffer) {
            out.append(datagram)
        }
        return out
    }

    /// The oldest queued datagram, or nil when none is queued. Grows
    /// `buffer` once when the datagram does not fit.
    private func popDatagram(into buffer: inout [UInt8]) throws(RemoteRdCoreError) -> Data? {
        var length = 0
        var code = buffer.withUnsafeMutableBufferPointer { out in
            cmux_rd_upstream_pop_datagram(handle, out.baseAddress, out.count, &length)
        }
        if code == CMUX_RD_ERR_BUFFER {
            buffer = [UInt8](repeating: 0, count: length)
            code = buffer.withUnsafeMutableBufferPointer { out in
                cmux_rd_upstream_pop_datagram(handle, out.baseAddress, out.count, &length)
            }
        }
        guard try RemoteRdCoreError.check(code) == 1 else { return nil }
        return Data(buffer[0..<length])
    }

    /// The bitrate the encoder should aim for now.
    public func targetBitsPerSecond(nowMicros: UInt64) -> UInt64 {
        cmux_rd_upstream_target_bps(handle, nowMicros)
    }

    /// Reports a path change (the link moved to another path class).
    func setPath(_ path: UInt32) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_upstream_set_path(handle, path))
    }

    /// Counters for the indicator and the status line.
    public func stats() -> RemoteRdUpstreamStats {
        var raw = CmuxRdUpstreamStats()
        _ = cmux_rd_upstream_stats(handle, &raw)
        return RemoteRdUpstreamStats(
            framesSent: raw.frames_sent,
            framesDropped: raw.frames_dropped,
            ackedFrame: raw.acked_frame,
            lossPartsPerMillion: raw.loss_ppm,
            keyframeRequested: raw.keyframe_requested,
            consent: raw.consent
        )
    }
}

/// Upstream sender counters for the indicator and the status line.
public nonisolated struct RemoteRdUpstreamStats: Sendable, Hashable {
    public var framesSent: UInt64
    public var framesDropped: UInt64
    /// Newest frame the host completed, 0 for none.
    public var ackedFrame: UInt32
    /// Smoothed loss in parts per million.
    public var lossPartsPerMillion: UInt32
    /// Make the next frame independent.
    public var keyframeRequested: Bool
    /// The app granted consent for this sender's kind.
    public var consent: Bool
}

/// What an upstream sender carries; each kind needs its own consent and its
/// own macOS permission (microphone, camera, screen recording).
public nonisolated enum RemoteUpstreamKind: String, Sendable, Hashable, CaseIterable {
    case microphone
    case camera
    case screen

    var raw: UInt32 {
        switch self {
        case .microphone: UInt32(CMUX_RD_MEDIA_MIC)
        case .camera: UInt32(CMUX_RD_MEDIA_CAMERA)
        case .screen: UInt32(CMUX_RD_MEDIA_SCREEN)
        }
    }

    /// The `stream_open` kind the host expects.
    public var streamKind: RemoteRdStreamKind { self == .microphone ? .upAudio : .upVideo }
    /// The `stream_open` codec the host expects.
    public var codec: String { self == .microphone ? "opus" : "h264" }
}
