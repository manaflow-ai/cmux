import CmuxMobileHost
import CmuxMobileWire
import Foundation

/// Signs the session hello with this device's paired key (B6: a Secure
/// Enclave P-256 key on iOS; a software key in tests).
public protocol MobileHelloSigner: Sendable {
    var client: HelloClient { get }
    func proof(hostID: String, sessionID: UUID) async throws -> DeviceProof
}
