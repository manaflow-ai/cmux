import CMUXMobileCore

struct TerminalScrollResponse: Sendable {
    let accepted: Bool
    let interactionEpoch: UInt64
    let clientRevision: UInt64
    let renderRevision: UInt64?
    let renderGrid: MobileTerminalRenderGridFrame?
}
