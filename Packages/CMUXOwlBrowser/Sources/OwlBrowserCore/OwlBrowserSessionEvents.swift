import Foundation
import OwlMojoBindingsGenerated

public struct OwlBrowserSessionEventSnapshot: Codable {
    public let ready: Bool
    public let disconnected: Bool
    public let contextID: UInt32
    public let contextGeneration: UInt64
    public let hostPID: Int32
    public let loading: Bool
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let url: String
    public let title: String
    public let surfaceTree: OwlFreshSurfaceTree?
    public let cursor: OwlFreshCursorInfo?
    public let logs: [String]
}

public final class OwlBrowserSessionEvents {
    private let lock = NSLock()
    private var ready = false
    private var disconnected = false
    private var contextID: UInt32 = 0
    private var contextGeneration: UInt64 = 0
    private var hostPID: Int32 = -1
    private var loading = true
    private var canGoBack = false
    private var canGoForward = false
    private var url = ""
    private var title = ""
    private var surfaceTree: OwlFreshSurfaceTree?
    private var cursor: OwlFreshCursorInfo?
    private var logs: [String] = []

    public init() {}

    public func recordLog(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        logs.append(message)
        if logs.count > 30 {
            logs.removeFirst(logs.count - 30)
        }
    }

    public func recordReady(hostPID: Int32, contextID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        ready = true
        if self.hostPID <= 0 {
            self.hostPID = hostPID
        }
        updateContextID(contextID)
    }

    public func recordHostPID(_ hostPID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.hostPID = hostPID
    }

    public func recordCompositor(contextID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        updateContextID(contextID)
    }

    public func recordNavigation(
        url: String,
        title: String,
        loading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.loading = loading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !url.isEmpty {
            self.url = url
        }
        if !title.isEmpty {
            self.title = title
        }
    }

    public func recordDisconnected() {
        lock.lock()
        defer { lock.unlock() }
        disconnected = true
        loading = false
    }

    public func recordSurfaceTree(_ surfaceTree: OwlFreshSurfaceTree) {
        lock.lock()
        defer { lock.unlock() }
        self.surfaceTree = surfaceTree
    }

    public func recordCursor(_ cursor: OwlFreshCursorInfo) {
        lock.lock()
        defer { lock.unlock() }
        self.cursor = cursor
    }

    public func snapshot() -> OwlBrowserSessionEventSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return OwlBrowserSessionEventSnapshot(
            ready: ready,
            disconnected: disconnected,
            contextID: contextID,
            contextGeneration: contextGeneration,
            hostPID: hostPID,
            loading: loading,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            url: url,
            title: title,
            surfaceTree: surfaceTree,
            cursor: cursor,
            logs: logs
        )
    }

    private func updateContextID(_ id: UInt32) {
        guard id != 0 else {
            return
        }
        contextID = id
        contextGeneration += 1
    }
}

extension OwlBrowserSessionEvents: OwlFreshClientMojoSink {
    public func onReady(_ request: OwlFreshClientOnReadyRequest) {
        recordReady(hostPID: request.hostPid, contextID: request.compositor.contextId)
    }

    public func onCompositorChanged(_ compositor: OwlFreshCompositorInfo) {
        recordCompositor(contextID: compositor.contextId)
    }

    public func onSurfaceTreeChanged(_ surfaceTree: OwlFreshSurfaceTree) {
        recordSurfaceTree(surfaceTree)
    }

    public func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest) {
        recordNavigation(
            url: request.url,
            title: request.title,
            loading: request.loading,
            canGoBack: request.canGoBack,
            canGoForward: request.canGoForward
        )
    }

    public func onHostLog(_ message: String) {
        recordLog(message)
    }

    public func onCursorChanged(_ cursor: OwlFreshCursorInfo) {
        recordCursor(cursor)
    }
}
