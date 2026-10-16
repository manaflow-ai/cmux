import CmuxSurfaceCatalogModel
import Foundation

/// Owns a machine's scan demand and last successful inventory independently of its workspace event feed.
struct CloudPortDiscovery: Sendable {
    private(set) var state: CloudPortDiscoveryState = .notRequested
    private(set) var scan: CloudPortScanResult?
    private(set) var wasRequested = false
    private var scannedAt: Date?
    private var socketPath: String?
    private var privateAddress: String?
    private var requestID: UInt64 = 0
    private var activeScan: UInt64?
    private var blocker: CloudPortDiscoveryState?
    private let cacheLifetime: TimeInterval = 30

    /// SSH machines reach their ports over the SSH link's loopback forward, so they opt in with `allowLoopback`.
    mutating func reconcile(supportsPreviews: Bool, isAwake: Bool, privateAddress: String?, allowLoopback: Bool = false) {
        let nextBlocker = CloudPortRoutePlan.blocker(
            supportsPreviews: supportsPreviews,
            privateAddress: privateAddress,
            allowLoopback: allowLoopback
        ) ?? (isAwake ? nil : .unavailable(.machineAsleep))
        if self.privateAddress != privateAddress || blocker != nextBlocker {
            requestID &+= 1
            scan = nil
            scannedAt = nil
            socketPath = nil
            self.privateAddress = privateAddress
            blocker = nextBlocker
            // Unchecked even when requested: a refresh still scans via `mayScan`, and a visible Ports group
            // re-requests `.notRequested`, which a summary update clearing the blocker needs (no refresh follows it).
            state = nextBlocker ?? .notRequested
        } else if let blocker {
            state = blocker
        }
    }

    /// Returns the token `abandonRequest` uses to tell whether a scan started since or is still running.
    @discardableResult
    mutating func request() -> UInt64 {
        wasRequested = true
        if blocker == nil { state = .loading }
        return requestID
    }

    /// A request cancelled before any scan picked it up stops showing loading. Demand stays, so the next refresh scans.
    mutating func abandonRequest(_ request: UInt64) {
        guard request == requestID, activeScan != requestID, state == .loading else { return }
        if let scan {
            state = scannedAt == nil ? .stale : scan.state
        } else {
            state = .notRequested
        }
    }

    var mayScan: Bool { wasRequested && blocker == nil }

    mutating func cachedScan(at now: Date, socketPath: String, force: Bool) -> CloudPortScanResult? {
        guard !force, self.socketPath == socketPath, let scannedAt,
              now.timeIntervalSince(scannedAt) < cacheLifetime else { return nil }
        if let scan { state = scan.state }
        return scan
    }

    /// A rescan keeps the settled result visible; only a machine with no inventory shows loading.
    mutating func beginScan() -> UInt64 {
        requestID &+= 1
        activeScan = requestID
        if let blocker {
            state = blocker
        } else if scan == nil {
            state = .loading
        }
        return requestID
    }

    /// Every scan ends here, including one cancelled before it could complete.
    mutating func endScan(_ request: UInt64) {
        if activeScan == request { activeScan = nil }
    }

    /// Late requests from an earlier address, lifecycle, or retry cannot replace the current result.
    @discardableResult
    mutating func complete(_ result: CloudPortScanResult?, request: UInt64, at now: Date, socketPath: String) -> Bool {
        guard request == requestID, blocker == nil else { return false }
        if let result {
            scan = result
            scannedAt = now
            self.socketPath = socketPath
            state = result.state
        } else {
            scannedAt = nil
            state = scan == nil ? .unavailable(.transport) : .stale
        }
        return true
    }

    mutating func linkFailed() {
        guard blocker == nil, wasRequested else { return }
        requestID &+= 1
        scannedAt = nil
        state = scan == nil ? .unavailable(.link) : .stale
    }

    mutating func invalidate() {
        requestID &+= 1
        scannedAt = nil
        socketPath = nil
        if blocker == nil { state = scan == nil ? .notRequested : .stale }
    }
}
