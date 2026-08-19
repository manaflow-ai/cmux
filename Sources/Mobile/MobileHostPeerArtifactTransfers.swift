import CMUXMobileCore
import CmuxAgentChat
import CmuxPeerTransport
import Darwin
import Dispatch
import Foundation

/// The minimal outbound surface the artifact handler needs from a peer byte
/// stream. Tests fake this; production uses `PeerByteStream` directly.
protocol MobileHostPeerArtifactStreamWriting: Sendable {
    func write(_ data: Data) async throws
    func finish() async throws
    func reset(errorCode: UInt64) async
}

extension PeerByteStream: MobileHostPeerArtifactStreamWriting {}

enum MobileHostPeerArtifactTransferIssueFailure: Equatable, Sendable {
    case fileNotFound
    case permissionDenied
    case notRegularFile
    case readFailed
    case unavailable
}

/// Runtime-scoped, peer-bound capabilities minted only after control-RPC authorization.
actor MobileHostPeerArtifactTransferRegistry {
    enum Error: Swift.Error, Equatable {
        case unavailable
        case fileNotFound
        case permissionDenied
        case notRegularFile
        case readFailed
        case invalidFile
        case capacityExceeded
        case unknownResource
        case expired
        case peerMismatch
        case invalidOffset
        case alreadyInUse
        case resumeLimitExceeded

        var issueFailure: MobileHostPeerArtifactTransferIssueFailure {
            switch self {
            case .fileNotFound:
                .fileNotFound
            case .permissionDenied:
                .permissionDenied
            case .notRegularFile:
                .notRegularFile
            case .readFailed, .invalidFile:
                .readFailed
            case .unavailable, .capacityExceeded, .unknownResource, .expired,
                 .peerMismatch, .invalidOffset, .alreadyInUse, .resumeLimitExceeded:
                .unavailable
            }
        }
    }

    struct Lease: Equatable, Sendable {
        let id: UUID
        let resourceID: String
        let canonicalPath: String
        let identity: MobileHostPeerArtifactFileIdentity
        let offset: UInt64
        let totalSize: Int64
    }

    private struct Entry: Sendable {
        let peer: MobileHostPeerAdmission
        let canonicalPath: String
        let identity: MobileHostPeerArtifactFileIdentity
        let expiresAt: Date
        var activeLeaseID: UUID?
        var remainingClaims: Int
    }

    private static let maximumEntryCount = 128
    private static let maximumSerialClaimCount = 8
    private static let defaultTimeToLive: TimeInterval = 5 * 60

    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private let resourceID: @Sendable () throws -> String
    private var entries: [String: Entry] = [:]

    init(
        timeToLive: TimeInterval = defaultTimeToLive,
        // A closure literal, not `Date.init`: the initializer reference
        // resolves as a non-@Sendable function value and trips the Swift 6
        // data-race warning (zero-bucket file in the warning budget).
        now: @escaping @Sendable () -> Date = { Date() },
        resourceID: @escaping @Sendable () throws -> String = {
            let token = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            return "artifact:\(token)"
        }
    ) {
        self.timeToLive = max(1, timeToLive)
        self.now = now
        self.resourceID = resourceID
    }

    func issue(
        canonicalPath: String,
        peer: MobileHostPeerAdmission
    ) throws -> ChatArtifactLaneDescriptor {
        let currentTime = now()
        pruneExpired(at: currentTime)
        guard entries.count < Self.maximumEntryCount else {
            throw Error.capacityExceeded
        }
        let resolvedPath = URL(fileURLWithPath: canonicalPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let identity = try MobileHostPeerArtifactFileIdentity.snapshot(path: resolvedPath)
        guard identity.size >= 0 else { throw Error.invalidFile }
        let capability = try resourceID()
        guard entries[capability] == nil else { throw Error.capacityExceeded }
        let expiresAt = currentTime.addingTimeInterval(timeToLive)
        entries[capability] = Entry(
            peer: peer,
            canonicalPath: resolvedPath,
            identity: identity,
            expiresAt: expiresAt,
            activeLeaseID: nil,
            remainingClaims: Self.maximumSerialClaimCount
        )
        return ChatArtifactLaneDescriptor(
            resourceID: capability,
            totalSize: identity.size,
            expiresAt: expiresAt
        )
    }

    func claim(
        resourceID: String,
        offset: UInt64,
        peer: MobileHostPeerAdmission
    ) throws -> Lease {
        let currentTime = now()
        guard var entry = entries[resourceID] else { throw Error.unknownResource }
        guard entry.expiresAt > currentTime else {
            entries[resourceID] = nil
            throw Error.expired
        }
        guard entry.peer == peer else { throw Error.peerMismatch }
        guard offset <= UInt64(entry.identity.size) else { throw Error.invalidOffset }
        guard entry.activeLeaseID == nil else { throw Error.alreadyInUse }
        guard entry.remainingClaims > 0 else { throw Error.resumeLimitExceeded }
        let leaseID = UUID()
        entry.activeLeaseID = leaseID
        entry.remainingClaims -= 1
        entries[resourceID] = entry
        return Lease(
            id: leaseID,
            resourceID: resourceID,
            canonicalPath: entry.canonicalPath,
            identity: entry.identity,
            offset: offset,
            totalSize: entry.identity.size
        )
    }

    func release(_ lease: Lease) {
        guard var entry = entries[lease.resourceID],
              entry.activeLeaseID == lease.id else { return }
        entry.activeLeaseID = nil
        entries[lease.resourceID] = entry
    }

    private func pruneExpired(at currentTime: Date) {
        entries = entries.filter { _, entry in
            entry.activeLeaseID != nil || entry.expiresAt > currentTime
        }
    }
}

struct MobileHostPeerArtifactFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func snapshot(path: String) throws -> Self {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch POSIXErrorCode(rawValue: Darwin.errno) {
            case .ENOENT, .ESTALE:
                throw MobileHostPeerArtifactTransferRegistry.Error.fileNotFound
            case .EACCES, .EPERM:
                throw MobileHostPeerArtifactTransferRegistry.Error.permissionDenied
            default:
                throw MobileHostPeerArtifactTransferRegistry.Error.readFailed
            }
        }
        defer { _ = Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw MobileHostPeerArtifactTransferRegistry.Error.readFailed
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw MobileHostPeerArtifactTransferRegistry.Error.notRegularFile
        }
        return identity(from: value)
    }

    static func snapshot(fileDescriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG else {
            throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
        }
        return identity(from: value)
    }

    private static func identity(from value: stat) -> Self {
        return Self(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

/// Random-access file reader backed by DispatchIO so a slow file system never
/// blocks Swift's cooperative executor. Cancelling a lane stops pending I/O.
private final class MobileHostPeerArtifactDispatchReader: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "dev.cmux.mobile-host-peer-artifact-read",
        qos: .utility
    )

    private let fileDescriptor: Int32
    private let channel: DispatchIO

    init(path: String) throws {
        let fileDescriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
        }
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fileDescriptor)
            throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
        }
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            Darwin.close(fileDescriptor)
            throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
        }
        self.fileDescriptor = fileDescriptor
        self.channel = DispatchIO(
            type: .random,
            fileDescriptor: fileDescriptor,
            queue: Self.queue
        ) { _ in
            _ = Darwin.close(fileDescriptor)
        }
        channel.setLimit(lowWater: 1)
    }

    func snapshot() throws -> MobileHostPeerArtifactFileIdentity {
        try MobileHostPeerArtifactFileIdentity.snapshot(fileDescriptor: fileDescriptor)
    }

    func read(offset: UInt64, maximumByteCount: Int) async throws -> Data {
        guard offset <= UInt64(Int64.max), maximumByteCount > 0 else {
            throw MobileHostPeerArtifactTransferRegistry.Error.invalidOffset
        }
        try Task.checkCancellation()
        let channel = channel
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                let result = MobileHostPeerArtifactDispatchReadResult(
                    continuation: continuation
                )
                channel.read(
                    offset: off_t(offset),
                    length: maximumByteCount,
                    queue: Self.queue
                ) { done, bytes, errorCode in
                    result.receive(done: done, bytes: bytes, errorCode: errorCode)
                }
            }
        } onCancel: {
            channel.close(flags: .stop)
        }
        try Task.checkCancellation()
        return data
    }

    func close() {
        channel.close()
    }
}

/// DispatchIO may deliver one read through several callbacks on its serial queue.
private final class MobileHostPeerArtifactDispatchReadResult: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, any Error>
    private var data = Data()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func receive(done: Bool, bytes: DispatchData?, errorCode: Int32) {
        guard !didResume else { return }
        if let bytes {
            data.append(contentsOf: bytes)
        }
        guard done else { return }
        didResume = true
        if errorCode == 0 {
            continuation.resume(returning: data)
        } else {
            continuation.resume(
                throwing: POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            )
        }
    }
}

/// Concrete Mac owner for low-priority raw artifact bytes.
///
/// The previous transport lowered the artifact stream's QUIC priority below
/// terminal and server-event lanes; `PeerByteStream` does not expose stream
/// priorities, so all lanes currently share the default priority.
struct MobileHostPeerArtifactLaneHandler: MobileHostPeerArtifactLaneHandling {
    private static let chunkByteCount = 64 * 1_024
    private static let streamFailureCode: UInt64 = 6

    let registry: MobileHostPeerArtifactTransferRegistry

    func handleArtifactLane(
        resourceID: String,
        offset: UInt64,
        stream: any MobileHostPeerArtifactStreamWriting,
        peer: MobileHostPeerAdmission
    ) async -> Bool {
        let lease: MobileHostPeerArtifactTransferRegistry.Lease
        do {
            lease = try await registry.claim(
                resourceID: resourceID,
                offset: offset,
                peer: peer
            )
        } catch {
            return false
        }

        do {
            let reader = try MobileHostPeerArtifactDispatchReader(path: lease.canonicalPath)
            defer { reader.close() }
            guard try reader.snapshot() == lease.identity else {
                throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
            }
            let totalSize = UInt64(lease.totalSize)
            var readOffset = lease.offset
            while readOffset < totalSize {
                try Task.checkCancellation()
                let remainingByteCount = totalSize - readOffset
                let readByteCount = Int(min(
                    UInt64(Self.chunkByteCount),
                    remainingByteCount
                ))
                let data = try await reader.read(
                    offset: readOffset,
                    maximumByteCount: readByteCount
                )
                guard !data.isEmpty else {
                    throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
                }
                try Task.checkCancellation()
                try await stream.write(data)
                readOffset += UInt64(data.count)
            }
            try Task.checkCancellation()
            guard try reader.snapshot() == lease.identity else {
                throw MobileHostPeerArtifactTransferRegistry.Error.invalidFile
            }
            try await stream.finish()
        } catch is CancellationError {
            await stream.reset(errorCode: 0)
        } catch {
            await stream.reset(errorCode: Self.streamFailureCode)
        }
        await registry.release(lease)
        return true
    }
}

