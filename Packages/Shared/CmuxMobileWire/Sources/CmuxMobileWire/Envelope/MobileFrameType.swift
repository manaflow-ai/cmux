/// Every envelope `t` of cmux.mobile/1 (a0-rpc.md section 2).
public enum MobileFrameType: String, CaseIterable, Hashable, Sendable {
    case hello
    case helloOK = "hello.ok"
    case welcome
    case subscribe
    case unsubscribe
    case snapshotRequest = "snapshot.request"
    case op
    case read
    case readResult = "read.result"
    case result
    case reject
    case settled = "request-settled"
    case event
    case snapshot
    case presenceSet = "presence.set"
    case signal
    case error
    case channelOpen = "channel.open"
    case channelOpened = "channel.opened"
    case channelRefused = "channel.refused"
    case channelClose = "channel.close"
    case channelClosed = "channel.closed"
}
