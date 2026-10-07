public import CmuxLinkWebRTC
public import CmuxMobileHost

/// `HostControlUplink` hands relayed `signal` frames straight to the
/// WebRTC signaling channel (b2-webrtc.md, wiring for B5).
extension SignalFrameChannel: @retroactive SignalingSink {}
