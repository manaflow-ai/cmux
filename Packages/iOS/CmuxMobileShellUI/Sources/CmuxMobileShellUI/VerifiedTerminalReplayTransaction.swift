import CMUXMobileCore

struct VerifiedTerminalReplayTransaction {
    let id: UInt64
    let renderEpoch: String
    let renderRevision: UInt64
    let emissionRevision: UInt64 = 0
    let stateSeq: UInt64
    let expected: MobileTerminalRenderGridVisualSnapshot
}
