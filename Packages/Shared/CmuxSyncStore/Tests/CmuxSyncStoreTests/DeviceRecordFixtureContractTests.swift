import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxSyncStore


/// Golden-fixture contract for the `devices` collection payload. The fixtures in
/// `<package>/Fixtures/devices/*.json` are the single source of truth for the
/// DeviceRecord <-> SyncedDeviceRecord wire shape and are loaded by BOTH this
/// suite and `workers/presence/test/deviceRecord.test.ts`. A field rename,
/// retype, or removal on either side makes that side's decode diverge from
/// `_expected.json` and the suite goes red. Additive-only: add a field, add a
/// fixture, bump schemaVersion. See plans/feat-ios-device-list-v2/PLAN.md Stage 1.
@Suite struct DeviceRecordFixtureContractTests {
    /// `<package root>/Fixtures/devices`, derived from this source file's location
    /// so the same canonical directory is shared with the worker test.
    static func fixturesDir() -> URL {
        URL(filePath: #filePath)            // .../Tests/CmuxSyncStoreTests/SyncFrameAndProtocolTests.swift
            .deletingLastPathComponent()    // .../Tests/CmuxSyncStoreTests
            .deletingLastPathComponent()    // .../Tests
            .deletingLastPathComponent()    // .../CmuxSyncStore (package root)
            .appending(path: "Fixtures/devices")
    }

    static func loadObject(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixturesDir().appending(path: name))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The wire `kind` of a route, read back by re-encoding (no dependency on the
    /// enum's raw representation), so the assertion tracks exactly what crosses
    /// the wire.
    static func routeKind(_ route: CmxAttachRoute) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any]
        return (obj?["kind"] as? String) ?? "?"
    }

    @Test func everyFixtureMatchesContract() throws {
        let expected = try Self.loadObject("_expected.json")
        var checked = 0
        for (name, raw) in expected where !name.hasPrefix("_") {
            guard let exp = raw as? [String: Any] else { continue }
            let data = try Data(contentsOf: Self.fixturesDir().appending(path: name))
            let decoded = try? JSONDecoder().decode(SyncedDeviceRecord.self, from: data)
            let shouldDecode = (exp["decodes"] as? Bool) ?? true

            if !shouldDecode {
                #expect(decoded == nil, "\(name): must NOT decode as a device record")
                checked += 1
                continue
            }
            guard let rec = decoded else {
                Issue.record("\(name): expected to decode but did not")
                continue
            }
            if let v = exp["deviceId"] as? String { #expect(rec.deviceId == v, "\(name) deviceId") }
            if let v = exp["platform"] as? String { #expect(rec.platform == v, "\(name) platform") }
            if let v = exp["displayName"] as? String { #expect(rec.displayName == v, "\(name) displayName") }
            if let v = exp["ownerUserId"] as? String { #expect(rec.ownerUserId == v, "\(name) ownerUserId") }
            if let v = exp["lastSeenAtAtRev"] as? Double { #expect(rec.lastSeenAtAtRev == v, "\(name) lastSeenAtAtRev") }
            if let n = exp["instanceCount"] as? Int { #expect(rec.instances.count == n, "\(name) instanceCount") }
            if let insts = exp["instances"] as? [[String: Any]] {
                #expect(rec.instances.count == insts.count, "\(name) instances length")
                for (i, ei) in insts.enumerated() where i < rec.instances.count {
                    let inst = rec.instances[i]
                    if let tag = ei["tag"] as? String { #expect(inst.tag == tag, "\(name) instance[\(i)] tag") }
                    if let kinds = ei["routeKinds"] as? [String] {
                        let actual = try inst.routes.map { try Self.routeKind($0) }
                        #expect(actual == kinds, "\(name) instance[\(i)] routeKinds (unknown kinds must be dropped)")
                    }
                }
            }
            checked += 1
        }
        #expect(checked >= 5, "expected at least 5 fixtures checked, got \(checked)")
    }

    /// Ties the actual source struct to the lock: a stored property added to
    /// `SyncedDeviceRecord` / `InstanceRecord` without updating
    /// `device-record.fields.json` makes the reflected field set diverge and this
    /// fails. Closes the source-type -> lock drift path (an optional addition is
    /// otherwise source-compatible and still decodes every existing fixture).
    @Test func sourceFieldsMatchLock() throws {
        let lock = try Self.loadObject("device-record.fields.json")
        let types = lock["types"] as? [String: Any] ?? [:]
        func lockKeys(_ t: String) -> Set<String> { Set((types[t] as? [String: Any] ?? [:]).keys) }

        let recordSample = SyncedDeviceRecord(
            deviceId: "d", platform: "mac", displayName: nil, ownerUserId: nil,
            lastSeenAtAtRev: 0, instances: [])
        let recordFields = Set(Mirror(reflecting: recordSample).children.compactMap(\.label))
        let instanceSample = SyncedDeviceRecord.InstanceRecord(tag: "t", routes: [], lastSeenAtAtRev: 0)
        let instanceFields = Set(Mirror(reflecting: instanceSample).children.compactMap(\.label))

        #expect(recordFields == lockKeys("DeviceRecord"),
                "SyncedDeviceRecord fields \(recordFields.sorted()) != lock \(lockKeys("DeviceRecord").sorted())")
        #expect(instanceFields == lockKeys("DeviceInstanceRecord"),
                "InstanceRecord fields \(instanceFields.sorted()) != lock \(lockKeys("DeviceInstanceRecord").sorted())")
    }
}
