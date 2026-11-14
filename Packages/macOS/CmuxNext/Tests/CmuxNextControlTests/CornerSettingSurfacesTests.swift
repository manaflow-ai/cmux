import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// The one corner radius (`layout.paneCornerRadius`) and its padding (`layout.cornerPadding`) reach
/// every surface that edits settings: the Cmd-Shift-P palette lists their values, and an agent's
/// `cmux settings set` (CLI) or MCP `settings_set` (both are the socket's `settings.*` methods) sets,
/// reads back and unsets them with no confirmation sheet, while a value out of range is refused.
@MainActor @Suite(.serialized) struct CornerSettingSurfacesTests {
    nonisolated static let keys: [(String, Double, Double)] = [
        ("layout.paneCornerRadius", 14, 99),
        ("layout.cornerPadding", 4, 40),
    ]

    private func make() throws -> (ControlRouter, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-corner-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: settings.file, settingsWriter: settings,
                                   configuration: .init(requestDeadline: .seconds(10)))
        return (router, settings, directory)
    }

    private func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    /// The palette lists each key with number steps (the current value marked), and an agent may set it.
    @Test(arguments: keys)
    func thePaletteListsItAndAnAgentMaySetIt(key: String, value: Double, outOfRange _: Double) throws {
        let row = try #require(SettingsSchema.all.first { $0.id == key }, "\(key) has no schema row")
        #expect(row.isPaletteExposed, "\(key) is not in the palette")
        let options = row.paletteOptions(current: .number(value), themeColors: [])
        #expect(options.contains { $0.value == .number(value) && $0.isCurrent }, "\(key): the palette does not list \(value) as current")
        #expect(SettingsSchema.agentSettableKeys.contains(key), "\(key) needs the person's approval over the CLI and MCP")
        #expect(row.value(typed: String(value)) == .number(value), "\(key): the palette refuses a typed \(value)")
    }

    /// The CLI and MCP path: `settings.set` with no `confirm`, `settings.get`, `settings.unset`.
    @Test(arguments: keys)
    func theSocketSetsReadsAndUnsetsIt(key: String, value: Double, outOfRange: Double) async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = key.split(separator: ".").map(String.init)
        _ = try await call(router, "settings.set", ["path": .string(key), "value": .number(value)]).get()
        #expect(try await settings.file.value(at: path) == .number(value))
        let read = try await call(router, "settings.get", ["path": .string(key)]).get()
        #expect(read.compactText.contains(String(format: "%g", value)), "\(key): settings.get answered \(read.compactText)")
        guard case .failure = await call(router, "settings.set", ["path": .string(key), "value": .number(outOfRange)]) else {
            Issue.record("\(key) accepted \(outOfRange), out of range")
            return
        }
        _ = try await call(router, "settings.unset", ["path": .string(key)]).get()
        #expect(try await settings.file.value(at: path) == nil)
    }
}
