import CmuxMobileWire

/// The Mac-owned process sleep assertion exposed to a paired phone.
///
/// This is deliberately a small seam. The host owns the assertion token and
/// the phone only observes the current state or asks the host to change it.
public protocol MobileCaffeineControl: Sendable {
    func status() async -> Bool
    func set(enabled: Bool) async throws
}

/// Serves the read-only `caffeine.status` RPC.
public struct MobileCaffeineStatusReadHandler: MobileReadHandler {
    private let control: any MobileCaffeineControl

    public init(control: any MobileCaffeineControl) {
        self.control = control
    }

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        .object(["enabled": .bool(await control.status())])
    }
}
