import Foundation
import os

/// The verification substrate: every transport action emits one structured
/// event, mirrored to the unified log at notice (persisted) and to a JSON-
/// lines file the soak harness tails. A session end or dial start that the
/// harness cannot attribute to an expected reason fails the soak, so nothing
/// here is optional or sampled.
public struct PtxEvent: Sendable, Codable {
    public var seq: Int64
    /// Wall-clock epoch seconds (for humans and cross-device alignment).
    public var ts: Double
    /// Monotonic milliseconds since log creation (for durations; wall clock
    /// can step).
    public var mono: Int64
    public var kind: String
    public var peer: String?
    public var session: String?
    public var reason: String?
    public var ms: Int64?
    public var detail: [String: String]?
}

public final class PtxEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger
    private let fileHandle: FileHandle?
    private let origin: ContinuousClock.Instant
    private var seq: Int64 = 0
    private let encoder = JSONEncoder()

    /// `fileURL` is created (with intermediate directories) if missing;
    /// existing files are appended so app relaunches keep one timeline.
    public init(subsystem: String, category: String, fileURL: URL?) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.origin = ContinuousClock.now
        if let fileURL {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            self.fileHandle = try? FileHandle(forWritingTo: fileURL)
            _ = try? self.fileHandle?.seekToEnd()
        } else {
            self.fileHandle = nil
        }
    }

    public func emit(
        _ kind: String, peer: Data? = nil, session: String? = nil,
        reason: String? = nil, ms: Int64? = nil, detail: [String: String]? = nil
    ) {
        lock.lock()
        seq += 1
        let event = PtxEvent(
            seq: seq,
            ts: Date().timeIntervalSince1970,
            mono: Int64(origin.duration(to: .now).components.seconds) * 1000
                + Int64(origin.duration(to: .now).components.attoseconds / 1_000_000_000_000_000),
            kind: kind,
            peer: peer.map { Self.hex8($0) },
            session: session,
            reason: reason,
            ms: ms,
            detail: detail)
        if let line = try? encoder.encode(event) {
            fileHandle?.write(line)
            fileHandle?.write(Data("\n".utf8))
        }
        lock.unlock()

        let detailText =
            detail?.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ") ?? ""
        logger.notice(
            """
            ptx \(kind, privacy: .public) \
            peer=\(event.peer ?? "-", privacy: .public) \
            session=\(session ?? "-", privacy: .public) \
            reason=\(reason ?? "-", privacy: .public) \
            ms=\(ms.map(String.init) ?? "-", privacy: .public) \
            \(detailText, privacy: .public)
            """)
    }

    /// Milliseconds elapsed since `start`, for dial/reconnect durations.
    public func elapsedMs(since start: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: .now)
        return Int64(duration.components.seconds) * 1000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    public static func hex8(_ data: Data) -> String {
        data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Event kinds, centralized so the soak harness and the emitters can't drift.
public enum PtxEventKind {
    public static let endpointBinding = "endpoint-binding"
    public static let endpointReady = "endpoint-ready"
    public static let endpointFailed = "endpoint-failed"
    public static let dialStart = "dial-start"
    public static let dialConnected = "dial-connected"
    public static let dialAdmitted = "dial-admitted"
    public static let dialFailed = "dial-failed"
    public static let dialJoined = "dial-joined"
    public static let sessionReady = "session-ready"
    public static let sessionEnd = "session-end"
    public static let reconnectScheduled = "reconnect-scheduled"
    public static let stateChanged = "state-changed"
    public static let admissionStart = "admission-start"
    public static let admissionAdmitted = "admission-admitted"
    public static let admissionDenied = "admission-denied"
    public static let credentialMinted = "credential-minted"
    public static let credentialCached = "credential-cached"
    public static let credentialRotated = "credential-rotated"
    public static let credentialPushed = "credential-pushed"
    public static let credentialReceived = "credential-received"
    public static let credentialError = "credential-error"
    public static let laneOpened = "lane-opened"
    public static let laneClosed = "lane-closed"
    public static let livenessPing = "liveness-ping"
    public static let livenessPong = "liveness-pong"
    public static let livenessDegraded = "liveness-degraded"
    public static let frameError = "frame-error"
    public static let bridgeEvent = "bridge"
}
