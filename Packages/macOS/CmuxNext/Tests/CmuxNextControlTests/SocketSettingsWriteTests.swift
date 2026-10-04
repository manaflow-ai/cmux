import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The socket writes settings only through the settings owner
/// (plans/cmux-next/settings-surfaces.md). These iterate `SettingsSchema.all`,
/// so a new descriptor is covered with no edit: it sets, reads back and
/// resets over the socket with schema validation, a value of the wrong type
/// is refused, and a managed key is refused on every write method.
@MainActor @Suite(.serialized) struct SocketSettingsWriteTests {
    func make(managed: ManagedPreferences = ManagedPreferences()) throws -> (ControlRouter, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-settings-surfaces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        // The full package suite runs other main-actor tests in parallel. Give
        // this file-backed round trip enough room to cross the actor boundary
        // without changing the production two-second socket deadline.
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: settings.file, settingsWriter: settings,
                                   configuration: .init(requestDeadline: .seconds(10)))
        return (router, settings, directory)
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    /// Each setting round-trips over the socket through the settings owner,
    /// and a value of the wrong type is refused before the file changes.
    @Test func everySettingSetsReadsAndResetsOverTheSocket() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        for descriptor in SettingsSchema.all {
            let key = JSONValue.string(descriptor.id)
            let before = settings.validatedWrites[descriptor.id, default: 0]
            let set = await call(router, "settings.set", ["path": key, "value": descriptor.sampleValue])
            #expect((try? set.get()) != nil, "\(descriptor.id): \(set)")
            #expect(settings.validatedWrites[descriptor.id, default: 0] == before + 1, "\(descriptor.id) skipped the settings owner")
            let read = try await settings.file.value(at: descriptor.path)
            #expect(read == descriptor.sampleValue, "\(descriptor.id)")
            guard case .failure(let refused) = await call(router, "settings.set", ["path": key, "value": ["wrong": true]]) else {
                Issue.record("\(descriptor.id) accepted a value of the wrong type")
                continue
            }
            #expect(refused.code == "invalid_params", "\(descriptor.id)")
            _ = try await call(router, "settings.reset", ["path": key]).get()
            #expect(try await settings.file.value(at: descriptor.path) == nil, "\(descriptor.id)")
        }
    }

    /// A managed key is refused on the socket, schema key or not.
    @Test func aManagedKeyIsRefused() async throws {
        let (router, settings, directory) = try make(managed: ManagedPreferences(forced: ["appearance.density": "compact"]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        for method in ["settings.set", "settings.reset", "settings.unset"] {
            guard case .failure(let error) = await call(router, method, ["path": "appearance.density", "value": "comfortable"]) else {
                Issue.record("\(method) wrote a managed key")
                continue
            }
            #expect(error.code == "managed", "\(method)")
        }
    }
}

extension SettingDescriptor {
    /// A value `accepts` takes: the default when there is one, else one that fits the kind.
    var sampleValue: JSONValue {
        if let defaultValue, accepts(defaultValue) { return defaultValue }
        switch kind {
        case .choice(let choices): return .string(choices.first?.value ?? "")
        case .choiceOrNumber(let choices, let number): return choices.first.map { .string($0.value) } ?? .number(number.range.lowerBound)
        case .toggle: return .bool(false)
        case .number(let number): return .number(number.range.lowerBound)
        case .color: return .string("#336699")
        case .sound: return .string("default")
        case .url: return .string("")
        case .hostList, .folderList: return .array([])
        case .timeRange: return .object(["start": .string("22:00"), "end": .string("07:00")])
        case .theme: return .string("Dracula")
        case .fontFamily: return .string("Menlo")
        }
    }
}
