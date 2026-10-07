import CmuxMobileWire

/// Receives `signal` frames `HostDO` relays to this Mac (seam for B2 WebRTC).
public protocol SignalingSink: Sendable {
    func receive(_ signal: SignalFrame) async
}
