@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// cmux Computer Use's settings (`computerUse.*`): on by default with Full access, the engine's
/// deny list as the default, an old `"enabled": false` read as mode "off" until the person picks
/// a mode, the retired keys refused, and no key an agent may set.
@MainActor @Suite(.serialized) struct ComputerUseSettingsTests {
    private func computerUse(_ root: JSONValue) -> ComputerUseSettings {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).computerUse
    }

    private func controller(_ json: String) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-computer-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        return (settings, home)
    }

    @Test func theDefaultIsFullAccessWithTheEngineDenyList() {
        let settings = computerUse(.object([:]))
        #expect(settings.mode == .fullAccess)
        #expect(settings.deniedApps == ComputerUseSettings.defaultDeniedApps)
        #expect(settings.allowOwnMachines && settings.pauseOnTakeover && settings.showCursor && settings.livePreview)
        #expect(!settings.allowForeground)
        let row = SettingsSchema.descriptor(for: ComputerUseSettings.modePath)
        #expect(row?.defaultValue == .string("fullAccess"))
    }

    /// A file written by an earlier Computer Use development build (`"mode": "standard"`, found in
    /// a real cmux-next.json) reads as the nearest mode today, with no invalid-value warning.
    @Test func earlierBuildModesReadAsTheNearestModeWithoutAWarning() {
        let cases: [(String, ComputerUseMode)] = [
            ("standard", .fullAccess), ("unrestricted", .fullAccess), ("bounded", .approvedApps), ("ask", .askEveryTime),
        ]
        for (raw, mode) in cases {
            let snapshot = CmuxConfigSnapshot.parse(.object(["computerUse": .object(["mode": .string(raw)])]),
                                                    validDensities: [], validMetrics: [])
            #expect(snapshot.computerUse.mode == mode, "\(raw)")
            #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("computerUse") }, "\(raw)")
        }
    }

    /// The Swift copy of the deny list is the engine's, entry for entry and in order.
    @Test func theDefaultDenyListMatchesTheEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "cmux-tui/crates/cmux-computer-use/src/policy.rs"), encoding: .utf8)
        let start = try #require(source.range(of: "pub fn default_denied_apps()"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        let engine = body.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        #expect(!engine.isEmpty)
        #expect(ComputerUseSettings.defaultDeniedApps == engine)
    }

    @Test(arguments: ComputerUseMode.allCases)
    func aModeInTheFileApplies(_ mode: ComputerUseMode) {
        let settings = computerUse(.object(["computerUse": .object(["mode": .string(mode.rawValue), "enabled": .bool(false)])]))
        #expect(settings.mode == mode, "a mode the person picked wins over the retired switch")
    }

    @Test func theRetiredSwitchOffIsModeOff() {
        #expect(computerUse(.object(["computerUse": .object(["enabled": .bool(false)])])).mode == .off)
        #expect(computerUse(.object(["computerUse": .object(["enabled": .bool(true)])])).mode == .fullAccess)
        let root = JSONValue.object(["computerUse": .object(["enabled": .bool(false)])])
        let row = SettingsSchema.descriptor(for: ComputerUseSettings.modePath)
        #expect(row?.storedValue(in: root) == .string("off"), "Settings shows the old switch as mode Off")
        #expect(row?.storedValue(in: .object(["computerUse": .object(["enabled": .bool(true)])])) == nil)
    }

    @Test func aDeniedAppsListReplacesTheDefaultAndABadOneKeepsIt() {
        let mine = computerUse(.object(["computerUse": .object(["deniedApps": .array([.string("com.example.a"), .string("com.example.a"), .string("name:Notes")])])]))
        #expect(mine.deniedApps == ["com.example.a", "name:Notes"])
        let snapshot = CmuxConfigSnapshot.parse(.object(["computerUse": .object(["deniedApps": .array([.number(1)])])]),
                                                validDensities: [], validMetrics: [])
        #expect(snapshot.computerUse.deniedApps == ComputerUseSettings.defaultDeniedApps)
        #expect(snapshot.diagnostics.contains { $0.path == "computerUse.deniedApps" })
        #expect(computerUse(.object(["computerUse": .object(["deniedApps": .array([])])])).deniedApps.isEmpty)
    }

    /// Picking a mode removes the old switch, so it never applies again behind a reset.
    @Test func writingTheModeRemovesTheRetiredSwitch() async throws {
        let (settings, home) = try controller(#"{ "computerUse": { "enabled": false, "driver": "legacy" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(settings.snapshot.computerUse.mode == .off)
        #expect(settings.snapshot.retiredKeys == ["computerUse.driver", "computerUse.enabled"])
        try await settings.setSetting(at: ComputerUseSettings.modePath, to: .string("lookOnly"), by: .user)
        #expect(try await settings.file.value(at: ComputerUseSettings.enabledPath) == nil)
        #expect(try await settings.file.value(at: ComputerUseSettings.modePath) == .string("lookOnly"))
        try await settings.setSetting(at: ComputerUseSettings.modePath, to: nil, by: .user)
        await settings.reload()
        #expect(settings.snapshot.computerUse.mode == .fullAccess)
    }

    @Test func theRetiredKeysAreRefused() async throws {
        let (settings, home) = try controller("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        for path in [ComputerUseSettings.enabledPath, ComputerUseSettings.driverPath] {
            #expect(SettingsSchema.isRetired(path))
            #expect(SettingsSchema.descriptor(for: path) == nil)
            await #expect(throws: SettingRetired.self) { try await settings.setSetting(at: path, to: .bool(true), by: .user) }
        }
    }

    /// No agent, CLI or MCP caller may change any computerUse.* key; the person may.
    @Test func everyComputerUseKeyIsTheUsersAlone() async throws {
        let keys = SettingsSchema.all.filter { $0.path.first == "computerUse" }
        #expect(Set(keys.map(\.id)) == ["computerUse.mode", "computerUse.deniedApps", "computerUse.allowOwnMachines",
                                         "computerUse.pauseOnTakeover", "computerUse.allowForeground", "computerUse.showCursor",
                                         "computerUse.livePreview", "computerUse.menus"])
        let (settings, home) = try controller("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        for row in keys {
            #expect(SettingsSchema.agentRefusedKeys[row.id] == .userOnly, Comment(rawValue: row.id))
            #expect(!SettingsSchema.agentSettableKeys.contains(row.id))
            let value = try #require(row.defaultValue)
            await #expect(throws: SettingUserOnly.self) { try await settings.setSetting(row, to: value, by: .caller("mcp")) }
        }
        try await settings.setSetting(at: ComputerUseSettings.modePath, to: .string("off"), by: .user)
        await settings.reload()
        #expect(settings.snapshot.computerUse.mode == .off)
    }

    @Test func thePolicyConfigIsTheEnginesShape() throws {
        var settings = ComputerUseSettings()
        settings.mode = .approvedApps
        settings.deniedApps = ["com.example.a"]
        settings.allowForeground = true
        let object = try #require(try JSONSerialization.jsonObject(with: settings.policyConfigJSON()) as? [String: Any])
        #expect(Set(object.keys) == ["mode", "deniedApps", "allowOwnMachines", "pauseOnTakeover", "allowForeground", "showCursor", "cloudVm", "menus"])
        #expect(object["mode"] as? String == "approvedApps")
        #expect(object["deniedApps"] as? [String] == ["com.example.a"])
        #expect(object["allowForeground"] as? Bool == true)
        #expect(object["cloudVm"] as? Bool == false)
        #expect(object["menus"] as? String == "open")
    }

    /// `computerUse.menus` reads `open` or `refuse` (default `open`); another value keeps the default
    /// with a diagnostic, and the engine gets the value as `menus`.
    @Test func menusReadsOpenOrRefuse() throws {
        #expect(computerUse(.object([:])).menus == .open)
        #expect(SettingsSchema.descriptor(for: ComputerUseSettings.menusPath)?.defaultValue == .string("open"))
        let settings = computerUse(.object(["computerUse": .object(["menus": .string("refuse")])]))
        #expect(settings.menus == .refuse)
        let object = try #require(try JSONSerialization.jsonObject(with: settings.policyConfigJSON()) as? [String: Any])
        #expect(object["menus"] as? String == "refuse")
        let odd = CmuxConfigSnapshot.parse(.object(["computerUse": .object(["menus": .string("sometimes")])]),
                                           validDensities: [], validMetrics: [])
        #expect(odd.computerUse.menus == .open)
        #expect(odd.diagnostics.contains { $0.path == "computerUse.menus" })
    }

    @Test func remoteEnabledIsRetired() {
        #expect(SettingsSchema.retiredKeys["remote.enabled"] != nil)
        #expect(!SettingsSchema.all.contains { $0.path == ["remote", "enabled"] })
    }
}
