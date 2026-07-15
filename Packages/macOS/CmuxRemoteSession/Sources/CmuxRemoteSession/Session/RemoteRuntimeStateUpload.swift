internal import Foundation

/// Latest client workspace snapshot waiting to be committed to a remote runtime.
struct RemoteRuntimeStateUpload: Sendable {
    let schemaVersion: Int
    let state: Data
}
