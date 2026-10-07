public import CmuxLink

/// An admitted `cmux.mobile/1` session to one Mac: the link after a
/// successful `hello` on channel 0 (b5-mac-host.md section 3), plus the
/// session's A0 channel id allocator. The session owner (D1/B6) dials,
/// proves the device and hands this to features; features never dial.
public protocol MobileSessionLink: Sendable {
    var link: any CmuxLink { get }
    /// The next unused odd A0 channel id of this session.
    func allocateChannelID() async -> UInt32
}
