import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxNextDesign

/// A choice type for tests.
enum TestSpeed: String, CaseIterable, TunableChoice {
    case fast, normal, off
    var tunableTitle: String { rawValue }
}

/// Records an Observation change callback.
nonisolated final class ChangeFlag: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// The tunable registry: defaults from code, clamped overrides, resets,
/// the inert store of builds without Debug Settings, and the file format.
/// Every test uses its own store; the shared one stays inert, so other
/// suites keep reading code defaults.
@Suite struct TunableStoreTests {
    static let section = TunableSection(id: "test", title: "Test", symbol: "testtube.2", order: 99)
    static let width = Tunable<Double>.number("test.width", section, "Width", help: "A width.", default: 12, range: 0...40, step: 1, unit: .points)
    static let enabled = Tunable<Bool>.toggle("test.enabled", section, "Enabled", help: "On or off.", default: true)
    static let spring = Tunable<SpringParameters>.spring("test.spring", section, "Spring", help: "A spring.",
                                                         default: SpringParameters(response: 0.2, dampingFraction: 0.9))
    static let color = Tunable<TunableColor>.color("test.color", section, "Color", help: "A color.", default: .textPrimary)
    static let speed = Tunable<TestSpeed>.choice("test.speed", section, "Speed", help: "A choice.", default: .fast)

    func activeStore() -> TunableStore {
        let store = TunableStore()
        store.register([Self.width.descriptor, Self.enabled.descriptor, Self.spring.descriptor, Self.color.descriptor, Self.speed.descriptor])
        store.activate(file: nil)
        return store
    }

    @Test func readsTheCodeDefaultWithoutAnOverride() {
        let store = activeStore()
        #expect(Self.width.value(in: store) == 12)
        #expect(Self.enabled.value(in: store) == true)
        #expect(Self.speed.value(in: store) == .fast)
        #expect(Self.width.override(in: store) == nil)
    }

    @Test func anInactiveStoreNeverApplies() {
        // Release and RC builds never activate the store.
        let store = TunableStore()
        store.register([Self.width.descriptor])
        store.set("test.width", .number(30))
        #expect(!store.isActive)
        #expect(Self.width.value(in: store) == 12)
    }

    @Test func clampsNumbersAndSpringsAndRefusesWrongTypes() {
        let store = activeStore()
        #expect(store.set("test.width", .number(99)) == .number(40))
        #expect(Self.width.value(in: store) == 40)
        #expect(store.set("test.width", .number(-5)) == .number(0))
        #expect(store.set("test.width", .bool(true)) == nil)
        #expect(store.set("test.width", .number(.nan)) == nil)
        #expect(Self.width.value(in: store) == 0)
        #expect(store.set("test.speed", .choice("warp")) == nil)
        #expect(store.set("test.speed", .choice("off")) == .choice("off"))
        #expect(Self.speed.value(in: store) == .off)
        let clamped = store.set("test.spring", .spring(SpringParameters(response: 9, dampingFraction: 0)))
        #expect(clamped == .spring(SpringParameters(response: TunableKind.springResponseRange.upperBound,
                                                    dampingFraction: TunableKind.springDampingRange.lowerBound)))
        #expect(store.set("test.unknown", .number(1)) == nil)
    }

    @Test func resetsOneSeveralAndAll() {
        let store = activeStore()
        store.set("test.width", .number(20))
        store.set("test.enabled", .bool(false))
        store.set("test.color", .color(.danger))
        store.reset(["test.width"])
        #expect(Self.width.value(in: store) == 12)
        #expect(Self.enabled.value(in: store) == false)
        store.set(Self.enabled.key, nil)
        #expect(Self.enabled.value(in: store) == true)
        store.resetAll()
        #expect(store.overrides.isEmpty)
        #expect(Self.color.value(in: store) == .textPrimary)
    }

    @Test func notifiesObserversOfTheChangedKeyOnly() {
        let store = activeStore()
        let widthChanged = ChangeFlag()
        let enabledChanged = ChangeFlag()
        withObservationTracking { _ = Self.width.value(in: store) } onChange: { widthChanged.set() }
        withObservationTracking { _ = Self.enabled.value(in: store) } onChange: { enabledChanged.set() }
        store.set("test.width", .number(14))
        #expect(widthChanged.value)
        #expect(!enabledChanged.value)
    }

    @Test func fileRoundTripKeepsEveryKindAndDropsBadValues() {
        let store = activeStore()
        let data = TunableFile.encode([
            "test.width": .number(18), "test.enabled": .bool(false), "test.speed": .choice("normal"),
            "test.color": .color(.attention), "test.spring": .spring(SpringParameters(response: 0.3, dampingFraction: 0.8)),
        ])
        var raw = TunableFile.decode(data)
        raw["test.unknown"] = 3
        raw["test.speed"] = raw["test.speed"]
        store.load(raw: raw)
        #expect(Self.width.value(in: store) == 18)
        #expect(Self.enabled.value(in: store) == false)
        #expect(Self.speed.value(in: store) == .normal)
        #expect(Self.color.value(in: store) == .attention)
        #expect(Self.spring.value(in: store) == SpringParameters(response: 0.3, dampingFraction: 0.8))
        #expect(store.overrides["test.unknown"] == nil)
        // A number where a bool belongs, and a bool where a number belongs.
        let fresh = activeStore()
        fresh.load(raw: ["test.enabled": 1, "test.width": true])
        #expect(fresh.overrides.isEmpty)
        // A value set since launch wins over the file's.
        fresh.set("test.width", .number(3))
        fresh.load(raw: ["test.width": 30, "test.enabled": false])
        #expect(Self.width.value(in: fresh) == 3)
        #expect(Self.enabled.value(in: fresh) == false)
    }

    @Test func persistsToTheOverrideFileAndLoadsItBack() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tunables-\(UUID().uuidString)/debug-tunables.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = TunableStore()
        writer.register([Self.width.descriptor])
        writer.activate(file: url)
        writer.set("test.width", .number(21))
        // The writer runs off the main actor; give it a bounded moment.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reader = TunableStore()
        reader.register([Self.width.descriptor])
        reader.activate(file: url)
        for _ in 0..<200 where Self.width.override(in: reader) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Self.width.value(in: reader) == 21)
    }
}
