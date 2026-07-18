internal import Foundation

internal struct BackendServicePairManifest: Codable, Equatable, Sendable {
    internal struct Artifact: Codable, Equatable, Sendable {
        let fileName: String
        let sha256: String
        let size: UInt64
    }

    let schemaVersion: Int
    let bundleIdentifier: String
    let serviceLabel: String
    let buildID: String
    let backend: Artifact
    let renderer: Artifact
}
