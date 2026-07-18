internal import Darwin
internal import Foundation
internal import Security
internal import CmuxTerminalRenderProtocol

/// Creates random per-worker endpoint names and capabilities.
struct TerminalRenderFrameEndpointFactory: Sendable {
    func makeEndpoint() throws -> TerminalRenderFrameEndpoint {
        var capability = [UInt8](
            repeating: 0,
            count: TerminalRenderFrameProtocol.capabilityLength
        )
        let status = SecRandomCopyBytes(kSecRandomDefault, capability.count, &capability)
        guard status == errSecSuccess else {
            throw TerminalRenderFrameTransportError.randomCapabilityFailed(status)
        }
        return try TerminalRenderFrameEndpoint(
            serviceName: "dev.cmux.render-frame.\(getpid()).\(UUID().uuidString)",
            capability: Data(capability)
        )
    }
}
