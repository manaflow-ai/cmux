public import CmuxMobileWire

/// The Mac's iOS simulators as a phone may see them (c14-web.md section 6).
public protocol SimulatorCaptureHost: Sendable {
    /// Simulators to offer, booted first.
    func simulators() async throws -> [SimulatorInfo]
    /// Attaches to a booted simulator; throws `SimulatorCaptureError`.
    func attach(_ request: SimulatorAttachRequest) async throws -> any SimulatorAttachment
}
