import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedPluginWriterHandoffFreshnessTests {
    private func handoff() throws -> (NestedPluginWriterHandoff, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (NestedPluginWriterHandoff(directoryURL: root), root)
    }

    @Test func acquireIsHeldThenReleaseClears() throws {
        let (store, _) = try handoff()
        let host = UUID()
        let attachment = UUID()
        try store.acquire(hostStableSurfaceID: host, attachmentID: attachment)
        #expect(store.isHeld(hostStableSurfaceID: host))
        try store.release(hostStableSurfaceID: host)
        #expect(!store.isHeld(hostStableSurfaceID: host))
    }

    @Test func staleHeartbeatIsNotHeld() throws {
        let (store, root) = try handoff()
        let host = UUID()
        let attachment = UUID()
        try store.acquire(hostStableSurfaceID: host, attachmentID: attachment)
        let url = store.lockFileURL(for: host)
        let stale: [String: Any] = [
            "attachment_id": attachment.uuidString.lowercased(),
            "host_stable_surface_id": host.uuidString.lowercased(),
            "state": "live",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "heartbeat_ms": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
        #expect(!store.isHeld(hostStableSurfaceID: host, nowMs: 1_000_000, ttlMs: 45_000))
        _ = root
    }

    @Test func deadPidIsNotHeld() throws {
        let (store, _) = try handoff()
        let host = UUID()
        let attachment = UUID()
        try store.acquire(hostStableSurfaceID: host, attachmentID: attachment)
        let url = store.lockFileURL(for: host)
        let dead: [String: Any] = [
            "attachment_id": attachment.uuidString.lowercased(),
            "host_stable_surface_id": host.uuidString.lowercased(),
            "state": "live",
            "pid": 999_999_999,
            "heartbeat_ms": RemoteHerdrHandoff.nowMs(),
        ]
        let data = try JSONSerialization.data(withJSONObject: dead, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
        #expect(!store.isHeld(hostStableSurfaceID: host))
    }

    @Test func missingReleaseIsIdempotent() throws {
        let (store, _) = try handoff()
        try store.release(hostStableSurfaceID: UUID())
    }
}
