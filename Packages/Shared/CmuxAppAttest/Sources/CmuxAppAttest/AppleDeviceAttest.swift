import DeviceCheck
public import Foundation

/// ``DeviceAttesting`` over `DCAppAttestService` and `DCDevice`.
///
/// The composition root passes the system services, so no code here reaches
/// for a shared instance:
///
/// ```swift
/// let attest = AppleDeviceAttest(service: .shared, device: .current)
/// ```
public struct AppleDeviceAttest: DeviceAttesting, @unchecked Sendable { // crash-allow: DCAppAttestService and DCDevice are thread-safe system singletons with no mutable state of ours
    private let service: DCAppAttestService
    private let device: DCDevice

    /// Wraps the system services.
    /// - Parameter service: `DCAppAttestService.shared`.
    /// - Parameter device: `DCDevice.current`.
    public init(service: DCAppAttestService, device: DCDevice) {
        self.service = service
        self.device = device
    }

    public var isSupported: Bool { service.isSupported }

    public func generateKey() async throws -> String {
        guard service.isSupported else { throw DeviceAttestError.unsupported }
        do { return try await service.generateKey() } catch { throw Self.map(error) }
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard service.isSupported else { throw DeviceAttestError.unsupported }
        do { return try await service.attestKey(keyID, clientDataHash: clientDataHash) } catch { throw Self.map(error) }
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard service.isSupported else { throw DeviceAttestError.unsupported }
        do { return try await service.generateAssertion(keyID, clientDataHash: clientDataHash) } catch { throw Self.map(error) }
    }

    public func deviceCheckToken() async throws -> Data {
        guard device.isSupported else { throw DeviceAttestError.unsupported }
        do { return try await device.generateToken() } catch { throw Self.map(error) }
    }

    private static func map(_ error: any Error) -> DeviceAttestError {
        guard let error = error as? DCError else { return .failed }
        switch error.code {
        case .featureUnsupported: return .unsupported
        case .invalidKey: return .invalidKey
        default: return .failed
        }
    }
}
