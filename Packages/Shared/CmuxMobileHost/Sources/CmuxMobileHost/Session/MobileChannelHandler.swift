import CmuxMobileWire

/// Serves one channel kind the core does not (seam for C2 browser, C3 rd,
/// C4 files). The handler owns the channel after `channel.open`: it sends
/// `channel.opened` or calls `refuse`, and returns when the channel ends.
public protocol MobileChannelHandler: Sendable {
    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal) async
}
