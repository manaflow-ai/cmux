public import Foundation

/// One daemon's icon asset store.
public struct IconAssetClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// Stores one icon asset and returns its record (`icon` is the value to set).
    public func put(mediaType: String, data: Data) async throws -> IconAssetBlob {
        try await connection.request(PutBlobRequest(mediaType: mediaType, data: data))
    }

    /// The stored bytes of `blob` (a `blob:` ref or an asset icon value) and their media type.
    public func get(_ blob: String) async throws -> (data: Data, mediaType: String) {
        let blob = try await connection.request(GetBlobRequest(blob: blob))
        guard let data = blob.data.flatMap({ Data(base64Encoded: $0) }) else {
            throw DaemonError.malformedResponse("get-blob without base64 data")
        }
        return (data, blob.mediaType)
    }
}
