import CMUXMobileCore
import CoreGraphics

/// One display-link-coalesced scroll event awaiting RPC delivery.
struct BrowserStreamScrollBatch: Equatable, Sendable {
    var delta: CGPoint
    let phase: MobileBrowserScrollPhase
}
