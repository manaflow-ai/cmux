import CmuxMobileWire

/// Serves one `read` op on the `rpc` channel (seam for C4 `files.list`).
/// Throw `MobileDaemonError` to answer `error`.
public protocol MobileReadHandler: Sendable {
    func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue
}
