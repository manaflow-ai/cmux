internal import CmuxMobileRPC
internal import Foundation

/// Streams one app-owned file to the host's validated attachment store.
actor MobileAttachmentRPCUploader {
    struct Receipt: Sendable, Equatable {
        let operationID: UUID
        let uploadID: UUID
        let hostPath: String
    }

    private static let chunkByteCount = 3 * 1024 * 1024
    private let client: MobileCoreRPCClient

    init(client: MobileCoreRPCClient) {
        self.client = client
    }

    func upload(
        fileURL: URL,
        byteCount: Int,
        fileName: String,
        operationID: UUID,
        uploadID: UUID,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Receipt {
        let actualSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actualSize == byteCount else {
            throw MobileShellConnectionError.invalidResponse
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let remaining = byteCount - offset
            let requested = min(Self.chunkByteCount, max(remaining, 0))
            let chunk = requested == 0 ? Data() : try handle.read(upToCount: requested) ?? Data()
            guard chunk.count == requested else {
                throw MobileShellConnectionError.invalidResponse
            }
            let isLast = offset + chunk.count == byteCount
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.task.attachment.upload",
                params: [
                    "operation_id": operationID.uuidString,
                    "upload_id": uploadID.uuidString,
                    "file_name": fileName,
                    "total_bytes": byteCount,
                    "offset": offset,
                    "data_b64": chunk.base64EncodedString(),
                    "last": isLast,
                ]
            )
            let response = try await client.sendRequest(request)
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            guard let object,
                  object["received_bytes"] as? Int == offset + chunk.count else {
                throw MobileShellConnectionError.invalidResponse
            }
            offset += chunk.count
            progress?(byteCount == 0 ? 1 : Double(offset) / Double(byteCount))
            if isLast {
                guard let path = object["path"] as? String, path.hasPrefix("/") else {
                    throw MobileShellConnectionError.invalidResponse
                }
                return Receipt(
                    operationID: operationID,
                    uploadID: uploadID,
                    hostPath: path
                )
            }
        } while offset < byteCount
        throw MobileShellConnectionError.invalidResponse
    }
}
