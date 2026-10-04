internal import CmuxAgentChat
internal import CmuxMobileRPC
internal import Foundation

enum MobileArtifactLaneFetchError: Error, Equatable {
    case invalidDescriptor
    case failedBeforeFirstByte
    case failedAfterFirstByte
}

/// Converts one raw Iroh artifact lane into the existing chunk/backpressure seam.
struct MobileArtifactLaneFetchLoop: Sendable {
    private static let maximumReceiveByteCount = 64 * 1_024

    func run(
        descriptor: ChatArtifactLaneDescriptor,
        connection: any MobileArtifactLaneConnection,
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (_ chunk: ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        do {
            let result = try await runOpenConnection(
                descriptor: descriptor,
                connection: connection,
                collectsData: collectsData,
                progress: progress,
                onChunk: onChunk
            )
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    private func runOpenConnection(
        descriptor: ChatArtifactLaneDescriptor,
        connection: any MobileArtifactLaneConnection,
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (_ chunk: ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        guard descriptor.totalSize >= 0 else {
            throw MobileArtifactLaneFetchError.invalidDescriptor
        }
        var result = Data()
        if collectsData,
           descriptor.totalSize > 0,
           descriptor.totalSize <= Int64(Int.max) {
            result.reserveCapacity(Int(descriptor.totalSize))
        }
        var offset: Int64 = 0
        var finalChunk: ChatArtifactChunk?
        while true {
            try Task.checkCancellation()
            let data: Data?
            do {
                data = try await connection.receive(
                    maximumByteCount: Self.maximumReceiveByteCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw offset == 0
                    ? MobileArtifactLaneFetchError.failedBeforeFirstByte
                    : MobileArtifactLaneFetchError.failedAfterFirstByte
            }
            guard let data else {
                if descriptor.totalSize == 0, offset == 0 {
                    let chunk = ChatArtifactChunk(
                        data: Data(),
                        offset: 0,
                        totalSize: 0,
                        eof: true
                    )
                    progress?(0, 0)
                    try await onChunk(chunk)
                    return result
                }
                guard offset == descriptor.totalSize else {
                    throw offset == 0
                        ? MobileArtifactLaneFetchError.failedBeforeFirstByte
                        : MobileArtifactLaneFetchError.failedAfterFirstByte
                }
                if let finalChunk {
                    try await onChunk(finalChunk)
                }
                return result
            }
            guard finalChunk == nil,
                  !data.isEmpty,
                  Int64(data.count) <= descriptor.totalSize - offset else {
                throw offset == 0
                    ? MobileArtifactLaneFetchError.failedBeforeFirstByte
                    : MobileArtifactLaneFetchError.failedAfterFirstByte
            }
            let chunkOffset = offset
            offset += Int64(data.count)
            let chunk = ChatArtifactChunk(
                data: data,
                offset: chunkOffset,
                totalSize: descriptor.totalSize,
                eof: offset == descriptor.totalSize
            )
            if collectsData {
                result.append(data)
            }
            progress?(offset, descriptor.totalSize)
            if chunk.eof {
                finalChunk = chunk
            } else {
                try await onChunk(chunk)
            }
        }
    }
}
