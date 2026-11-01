import Foundation

struct NativeInstallContext: Sendable {
    let account: String
    let user: String
    let install: String
    let environment: String
    let point: String
    let token: String
    let generation: UInt64
    let secureStorage: Bool
}

struct NativeDeviceProof: Codable, Sendable {
    let signedAt: Int64
    let nonce: String
    let signature: String
}
struct NativeDeviceDescription: Decodable, Sendable {
    let id: String
    let meshId: String
    let wgPublicKey: String
    let installPublicKey: String?
}
struct NativeDeviceList: Decodable, Sendable { let items: [NativeDeviceDescription] }
struct NativeDeviceReply: Decodable, Sendable { let device: NativeDeviceDescription }
struct NativeDevicePolicyIdentity: Decodable, Sendable {
    let tenantId: String
    let meshId: String
    let deviceId: String
    let wgPublicKey: String
    let installPublicKey: String
}
struct NativeHostNetwork: Decodable, Sendable {
    let state: String
    let tenant: String
    let mesh: String
    let device: String
}
struct NativeEnrollmentHost: Decodable, Sendable {
    let id: String
    let owner_user: String
    let enrolled_by: String
    let kind: String?
    let orphaned: Bool?
    let wg_public_key: String?
    let network: NativeHostNetwork?
}
struct NativeBindingAck: Decodable, Sendable { let host: String; let network: NativeHostNetwork }
struct NativeOwnerReply<T: Decodable & Sendable>: Decodable, Sendable { let ok: Bool; let value: T? }

struct NativeHostParams: Encodable, Sendable { let name: String; let platform = "macos" }
struct NativeBindParams: Encodable, Sendable {
    let host: String
    let mesh: String
    let device: String
    let wg_public_key: String
    let proof: NativeDeviceProof
}
struct NativeOwnerCall<P: Encodable & Sendable>: Encodable, Sendable {
    let op: String
    let params: P
    let idempotency_key: String
    let origin = "user"
}
struct NativeEnrollParams: Encodable, Sendable {
    let name: String
    let wgPublicKey: String
    let installPublicKey: String
    let signedAt: Int64
    let nonce: String
    let signature: String
}
