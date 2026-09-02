#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
public import Foundation

/// Single-writer handoff signal between native nested attachment and the cmux-herdr plugin.
///
/// ## Contract
///
/// When a native attachment becomes ``NestedConnectionState/live`` for a host
/// surface, cmux acquires this handoff. The cmux-herdr plugin MUST then avoid
/// projecting competing `herdr:*` status/title updates for that logical host
/// surface (log once and no-op). When the attachment leaves `live`, the handoff
/// is released and plugin fallback may resume.
///
/// Escape hatch: if `CMUX_NESTED_TOPOLOGY_FORCE_PLUGIN_WRITERS=1` is set in the
/// plugin's environment, the plugin may ignore the handoff (documented only;
/// native cmux still writes the lock for observability).
///
/// Signals provided:
/// 1. Lock file under an injectable directory:
///    `cmux-nested-native-live-<stable-surface-uuid>.lock`
/// 2. Environment key ``environmentKey`` listing active host surface UUIDs
///    (comma-separated) for in-process consumers that share the coordinator's
///    environment mirror.
///
/// Lock file contents are JSON with `attachment_id`, `host_stable_surface_id`,
/// `pid`, and `heartbeat_ms` — never a socket path or provider payload.
/// A dead pid or expired heartbeat does not hold the lock (same TTL contract
/// as ``RemoteHerdrHandoff``).
public struct NestedPluginWriterHandoff: Sendable {
    /// Environment variable listing host surfaces with a live native attachment.
    public static let environmentKey = "CMUX_NESTED_TOPOLOGY_NATIVE_LIVE"
    /// Plugin escape hatch to force plugin writers even when native is live.
    public static let forcePluginWritersEnvironmentKey = "CMUX_NESTED_TOPOLOGY_FORCE_PLUGIN_WRITERS"
    /// Lock file name prefix.
    public static let lockFileNamePrefix = "cmux-nested-native-live-"
    /// Lock file name suffix.
    public static let lockFileNameSuffix = ".lock"
    /// Freshness window matching ``RemoteHerdrHandoff/defaultTTLMs``.
    public static let defaultTTLMs = RemoteHerdrHandoff.defaultTTLMs

    /// Lock directory (Sendable value type). File I/O uses ``FileManager/default``
    /// at call sites — `FileManager` itself is not `Sendable`, so it must not be
    /// stored on this struct under Swift 6 concurrency checking.
    private let directoryURL: URL

    /// Creates a handoff manager writing locks under `directoryURL`.
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Lock file URL for a host stable surface.
    public func lockFileURL(for hostStableSurfaceID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            Self.lockFileName(for: hostStableSurfaceID),
            isDirectory: false
        )
    }

    /// Filename for a host stable surface lock.
    public static func lockFileName(for hostStableSurfaceID: UUID) -> String {
        "\(lockFileNamePrefix)\(hostStableSurfaceID.uuidString.lowercased())\(lockFileNameSuffix)"
    }

    /// Whether a *fresh* lock currently exists for the host surface.
    public func isHeld(
        hostStableSurfaceID: UUID,
        nowMs: Int = RemoteHerdrHandoff.nowMs(),
        ttlMs: Int = NestedPluginWriterHandoff.defaultTTLMs
    ) -> Bool {
        let url = lockFileURL(for: hostStableSurfaceID)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Legacy: bare existence without JSON — treat mtime as heartbeat.
            guard FileManager.default.fileExists(atPath: url.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date
            else { return false }
            let mtimeMs = Int(mtime.timeIntervalSince1970 * 1000)
            return (nowMs - mtimeMs) <= ttlMs
        }
        let pid = Self.intValue(object["pid"])
        var heartbeat = Self.intValue(object["heartbeat_ms"])
        if heartbeat <= 0 {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date
            {
                heartbeat = Int(mtime.timeIntervalSince1970 * 1000)
            } else {
                return false
            }
        }
        if pid > 0 {
            if !RemoteHerdrHandoff.pidAlive(Int32(pid)) { return false }
            return (nowMs - heartbeat) <= ttlMs
        }
        return (nowMs - heartbeat) <= ttlMs
    }

    /// Acquires the handoff for a live attachment.
    public func acquire(hostStableSurfaceID: UUID, attachmentID: UUID) throws {
        try writeLock(
            hostStableSurfaceID: hostStableSurfaceID,
            attachmentID: attachmentID,
            pid: ProcessInfo.processInfo.processIdentifier,
            heartbeatMs: RemoteHerdrHandoff.nowMs()
        )
    }

    /// Refresh heartbeat so a long-lived attachment does not look stale.
    public func heartbeat(hostStableSurfaceID: UUID, attachmentID: UUID) throws {
        try writeLock(
            hostStableSurfaceID: hostStableSurfaceID,
            attachmentID: attachmentID,
            pid: ProcessInfo.processInfo.processIdentifier,
            heartbeatMs: RemoteHerdrHandoff.nowMs()
        )
    }

    /// Releases the handoff so plugin fallback may resume.
    public func release(hostStableSurfaceID: UUID) throws {
        let fileManager = FileManager.default
        let url = lockFileURL(for: hostStableSurfaceID)
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            return
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
        {
            return
        }
    }

    /// Whether the plugin should suppress writers given a lock directory and optional env.
    ///
    /// - Parameters:
    ///   - hostStableSurfaceID: Host surface under consideration.
    ///   - environment: Process environment (defaults to current process).
    /// - Returns: `true` when native handoff is held and the force-plugin escape hatch is unset.
    public func shouldSuppressPluginWriters(
        hostStableSurfaceID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if Self.isTruthy(environment[Self.forcePluginWritersEnvironmentKey]) {
            return false
        }
        if isHeld(hostStableSurfaceID: hostStableSurfaceID) {
            return true
        }
        let live = environment[Self.environmentKey] ?? ""
        let tokens = live.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return tokens.contains(hostStableSurfaceID.uuidString.lowercased())
    }

    /// Builds the comma-separated environment value for currently live surfaces.
    public static func environmentValue(for hostStableSurfaceIDs: [UUID]) -> String {
        hostStableSurfaceIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
    }

    private func writeLock(
        hostStableSurfaceID: UUID,
        attachmentID: UUID,
        pid: Int32,
        heartbeatMs: Int
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "attachment_id": attachmentID.uuidString.lowercased(),
            "host_stable_surface_id": hostStableSurfaceID.uuidString.lowercased(),
            "state": NestedConnectionState.live.rawValue,
            "pid": Int(pid),
            "heartbeat_ms": heartbeatMs,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let url = lockFileURL(for: hostStableSurfaceID)
        try data.write(to: url, options: [.atomic])
        #if canImport(Darwin) || os(Linux)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return 0
    }
}
