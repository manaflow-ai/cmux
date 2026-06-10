import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


final class WorkspaceRemoteProxyBroker {
    enum Update {
        case connecting
        case ready(BrowserProxyEndpoint)
        case error(String)
    }

    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: WorkspaceRemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: WorkspaceRemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: WorkspaceRemoteDaemonProxyTunnel?
        var endpoint: BrowserProxyEndpoint?
        var restartWorkItem: DispatchWorkItem?
        var restartRetryCount = 0
        var subscribers: [UUID: (Update) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    static let shared = WorkspaceRemoteProxyBroker()

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    existing.restartRetryCount = 0
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    func listPTY(configuration: WorkspaceRemoteConfiguration) throws -> [[String: Any]] {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.listPTY()
        }
    }

    func closePTY(configuration: WorkspaceRemoteConfiguration, sessionID: String) throws {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.closePTY(sessionID: sessionID)
        }
    }

    func resizePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
        }
    }

    func detachPTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.detachPTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
        }
    }

    func startPTYBridge(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.startPTYBridge(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            )
        }
    }

    private func withReadyTunnel<T>(
        configuration: WorkspaceRemoteConfiguration,
        _ body: (WorkspaceRemoteDaemonProxyTunnel) throws -> T
    ) throws -> T {
        try queue.sync {
            let key = Self.transportKey(for: configuration)
            guard let entry = entries[key], let tunnel = entry.tunnel else {
                throw NSError(domain: "cmux.remote.pty", code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return try body(tunnel)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: retryDelay))")
                )
                scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = WorkspaceRemoteDaemonProxyTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            try tunnel.start()
            entry.tunnel = tunnel
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            entry.restartRetryCount = 0
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
            scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
        scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, baseDelay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }
        entry.restartRetryCount += 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: entry.restartRetryCount)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        configuration.proxyBrokerTransportKey
    }

    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }
}

