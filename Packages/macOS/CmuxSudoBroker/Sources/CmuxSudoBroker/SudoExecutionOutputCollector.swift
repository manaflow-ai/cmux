import Darwin
import Foundation

/// Drains execution output, strips broker control markers, and persists a fixed prefix.
struct SudoExecutionOutputCollector {
    static let maximumBytes = 16 * 1_024 * 1_024

    private let outputDescriptor: Int32
    private let readinessMarker: Data?
    private let controlMarkers: SudoExecutionControlMarkers
    private let passwordMarker = Data(SudoAuthenticationOutputDetector.passwordPrompt.utf8)
    // Keep a slice so consuming a prefix does not shift every buffered byte.
    private var pending = ArraySlice<UInt8>()
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
        pending.append(contentsOf: data)
        try processPending(isFinal: false)
    }

    mutating func finish() throws {
        try processPending(isFinal: true)
    }

    private mutating func processPending(isFinal: Bool) throws {
        var markers = activeMarkers()
        var matcher = SudoExecutionMarkerMatcher(markers: markers)
        while !pending.isEmpty {
            let scan = matcher.scan(pending, isFinal: isFinal)
            if let match = scan.match {
                let marker = markers[match.markerIndex]
                let consumedCount = match.offset + marker.bytes.count
                try persist(Data(pending.prefix(match.offset)))
                pending = pending.dropFirst(consumedCount)
                compactPending()
                switch marker.kind {
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
                markers = activeMarkers()
                matcher = SudoExecutionMarkerMatcher(markers: markers)
                continue
            }

            let retainedSuffixCount = isFinal ? 0 : scan.retainedSuffixLength
            let count = pending.count - retainedSuffixCount
            guard count > 0 else { return }
            try persist(Data(pending.prefix(count)))
            pending = pending.dropFirst(count)
            compactPending()
        }
    }

    private func activeMarkers() -> [SudoExecutionMarkerMatcher.Marker] {
        var markers: [SudoExecutionMarkerMatcher.Marker] = []
        if authenticationWindowOpen, !authenticationFailed {
            markers.append((bytes: Array(passwordMarker), kind: .authentication))
        }
        if !inputReady, let readinessMarker {
            markers.append((bytes: Array(readinessMarker), kind: .readiness))
        }
        markers.append(
            (bytes: Array(controlMarkers.executionTimedOut), kind: .privilegedTimeout)
        )
        markers.append(
            (bytes: Array(controlMarkers.cleanupFailed), kind: .privilegedCleanup)
        )
        markers.append(
            (bytes: Array(controlMarkers.transportFailed), kind: .privilegedTransport)
        )
        markers.append(
            (bytes: Array(controlMarkers.launchFailed), kind: .privilegedLaunch)
        )
        return markers
    }

    private mutating func compactPending() {
        guard pending.startIndex > 64 * 1_024 else { return }
        pending = ArraySlice(Array(pending))
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

    private enum Failure: Error {
        case read(Int32)
        case write(Int32)
    }
}
