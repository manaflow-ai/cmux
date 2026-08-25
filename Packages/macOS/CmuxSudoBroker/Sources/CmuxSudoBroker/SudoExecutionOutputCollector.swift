import Darwin
import Foundation

/// Drains execution output, strips broker control markers, and persists a fixed prefix.
struct SudoExecutionOutputCollector {
    static let maximumBytes = 16 * 1_024 * 1_024

    private let outputDescriptor: Int32
    private let readinessMarker: Data?
    private let controlMarkers: SudoExecutionControlMarkers
    private let passwordMarker = Data(SudoAuthenticationOutputDetector.passwordPrompt.utf8)
    private var pending = Data()
    private var persistedByteCount = 0
    private var authenticationWindowOpen = true
    private(set) var authenticationFailed = false
    private(set) var privilegedFailure: SudoExecutionWaitDisposition?
    private(set) var inputReady: Bool

    init(
        outputDescriptor: Int32,
        readinessMarker: Data?,
        controlMarkers: SudoExecutionControlMarkers
    ) {
        self.outputDescriptor = outputDescriptor
        self.readinessMarker = readinessMarker
        self.controlMarkers = controlMarkers
        inputReady = readinessMarker == nil
    }

    mutating func drain(from descriptor: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                try consume(Data(bytes.prefix(count)))
            } else if count == 0 {
                try processPending(isFinal: true)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                throw Failure.read(errno)
            }
        }
    }

    mutating func consume(_ data: Data) throws {
        pending.append(data)
        try processPending(isFinal: false)
    }

    mutating func finish() throws {
        try processPending(isFinal: true)
    }

    private mutating func processPending(isFinal: Bool) throws {
        while !pending.isEmpty {
            let markers = activeMarkers()
            let match = markers.compactMap { marker -> Match? in
                pending.range(of: marker.bytes).map {
                    Match(range: $0, kind: marker.kind)
                }
            }.min { $0.range.lowerBound < $1.range.lowerBound }

            if let match {
                try persist(Data(pending[..<match.range.lowerBound]))
                pending.removeSubrange(..<match.range.upperBound)
                switch match.kind {
                case .authentication:
                    authenticationFailed = true
                case .readiness:
                    inputReady = true
                    authenticationWindowOpen = false
                case .privilegedTimeout:
                    privilegedFailure = .privilegedTimedOut
                case .privilegedCleanup:
                    privilegedFailure = .privilegedCleanupFailed
                case .privilegedTransport, .privilegedLaunch:
                    privilegedFailure = .privilegedTransportFailed
                }
                continue
            }

            let retainedSuffixCount = isFinal
                ? 0
                : max(0, (markers.map { $0.bytes.count }.max() ?? 1) - 1)
            let persistedCount = max(0, pending.count - retainedSuffixCount)
            guard persistedCount > 0 else { return }
            try persist(Data(pending.prefix(persistedCount)))
            pending.removeFirst(persistedCount)
            return
        }
    }

    private func activeMarkers() -> [(bytes: Data, kind: MarkerKind)] {
        var markers: [(bytes: Data, kind: MarkerKind)] = []
        if authenticationWindowOpen, !authenticationFailed {
            markers.append((passwordMarker, .authentication))
        }
        if !inputReady, let readinessMarker {
            markers.append((readinessMarker, .readiness))
        }
        markers.append((controlMarkers.executionTimedOut, .privilegedTimeout))
        markers.append((controlMarkers.cleanupFailed, .privilegedCleanup))
        markers.append((controlMarkers.transportFailed, .privilegedTransport))
        markers.append((controlMarkers.launchFailed, .privilegedLaunch))
        return markers
    }

    private mutating func persist(_ data: Data) throws {
        let remaining = Self.maximumBytes - persistedByteCount
        guard remaining > 0, !data.isEmpty else { return }
        let data = data.prefix(remaining)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(
                    outputDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
                persistedByteCount += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw Failure.write(count == 0 ? EIO : errno)
            }
        }
    }

    private struct Match {
        let range: Range<Data.Index>
        let kind: MarkerKind
    }

    private enum MarkerKind {
        case authentication
        case readiness
        case privilegedTimeout
        case privilegedCleanup
        case privilegedTransport
        case privilegedLaunch
    }

    private enum Failure: Error {
        case read(Int32)
        case write(Int32)
    }
}
