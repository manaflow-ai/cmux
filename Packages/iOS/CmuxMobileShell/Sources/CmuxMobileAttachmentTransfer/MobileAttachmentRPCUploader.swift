package import CmuxMobileRPC
package import Foundation

/// Streams one app-owned file to the host's validated attachment store.
package actor MobileAttachmentRPCUploader {
    package struct Receipt: Sendable, Equatable {
        package let operationID: UUID
        package let uploadID: UUID
        package let hostPath: String
    }

    private static let chunkByteCount = 3 * 1024 * 1024
    private let client: MobileCoreRPCClient

    package init(client: MobileCoreRPCClient) {
        self.client = client
    }

    package func upload(
        fileURL: URL,
        byteCount: Int,
        fileName: String,
        operationID: UUID,
        uploadID: UUID,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Receipt {
        do {
            return try await uploadUnredacted(
                fileURL: fileURL,
                byteCount: byteCount,
                fileName: fileName,
                operationID: operationID,
                uploadID: uploadID,
                progress: progress
            )
        } catch {
            throw MobileAttachmentTransferError.sanitizing(error)
        }
    }

    private func uploadUnredacted(
        fileURL: URL,
        byteCount: Int,
        fileName: String,
        operationID: UUID,
        uploadID: UUID,
        progress: (@Sendable (Double) -> Void)?
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
                  let receivedBytes = object["received_bytes"] as? Int else {
                throw MobileShellConnectionError.invalidResponse
            }
            // The host's durable completion record is authoritative. A retry
            // starts at offset zero with the same identities; when the upload
            // already completed, the host immediately returns its full-byte
            // receipt instead of accepting this first chunk again.
            if receivedBytes == byteCount,
               let path = object["path"] as? String,
               path.hasPrefix("/") {
                progress?(1)
                return Receipt(
                    operationID: operationID,
                    uploadID: uploadID,
                    hostPath: path
                )
            }
            let nextOffset = offset + chunk.count
            // An incomplete response must acknowledge exactly this chunk. A
            // first-time final chunk is complete only with the absolute path
            // handled above; accepting a bare final byte count would lose the
            // host reference needed by the delivery call.
            guard receivedBytes == nextOffset, !isLast else {
                throw MobileShellConnectionError.invalidResponse
            }
            offset = nextOffset
            progress?(Double(offset) / Double(byteCount))
        } while offset < byteCount
        throw MobileShellConnectionError.invalidResponse
    }
}
