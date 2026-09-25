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
    private var blocker: CloudPortDiscoveryState?
    private let cacheLifetime: TimeInterval = 30

    mutating func reconcile(supportsPreviews: Bool, isAwake: Bool, privateAddress: String?) {
        let nextBlocker = CloudPortRoutePlan.blocker(supportsPreviews: supportsPreviews, privateAddress: privateAddress)
            ?? (isAwake ? nil : .unavailable(.machineAsleep))
        if self.privateAddress != privateAddress || blocker != nextBlocker {
            requestID &+= 1
            scan = nil
            scannedAt = nil
            socketPath = nil
            self.privateAddress = privateAddress
            blocker = nextBlocker
            state = nextBlocker ?? .notRequested
        } else if let blocker {
            state = blocker
        }
    }

    mutating func request() {
        wasRequested = true
        if blocker == nil { state = .loading }
    }

    var mayScan: Bool { wasRequested && blocker == nil }

    mutating func cachedScan(at now: Date, socketPath: String, force: Bool) -> CloudPortScanResult? {
        guard !force, self.socketPath == socketPath, let scannedAt,
              now.timeIntervalSince(scannedAt) < cacheLifetime else { return nil }
        if let scan { state = scan.state }
        return scan
    }

    mutating func beginScan() -> UInt64 {
        requestID &+= 1
        state = blocker ?? .loading
        return requestID
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
