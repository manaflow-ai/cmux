import CryptoKit
import Foundation

struct NativeDeviceRecord: Codable, Sendable {
    var privateKey: String
    var device: String?
    var key: Curve25519.KeyAgreement.PrivateKey { get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: privateKey) ?? Data()) } }
}

/// Device enrollment must keep one identity per account, team and mesh.
struct NativeDeviceStore: Sendable {
    let root: URL
    let namespace: String
    var file: URL { CloudPaths(root: root).privateKey }

    func loadOrCreate() throws -> NativeDeviceRecord {
        let paths = CloudPaths(root: root)
        try paths.prepare()
        return NativeDeviceRecord(privateKey: try paths.loadOrCreateKey().rawRepresentation.base64EncodedString())
    }
}
