import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSettings

@Suite("Setting changes applied through JSONConfigStore")
struct CmuxSettingChangeTests {
    private func fixture(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cmux.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func root(_ file: URL) throws -> [String: Any] {
        let data = try JSONCSanitizer().sanitize(Data(contentsOf: file))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func value(_ path: String, in file: URL) throws -> Any? {
        JSONPath(dottedPath: path).lookup(in: try root(file))
    }

    private let baseConfig = """
    {
      // keep this comment
      "actions": {
        "scroll.cycle": { "type": "setting", "path": "terminal.scrollSpeed", "cycle": [1.0, 1.4, 1.8] }
      },
      "terminal": { "scrollSpeed": 1.4 },
      "sidebar": { "showLog": true }
    }

    """

    @Test("set writes the value and keeps comments and unrelated keys")
    func setPreservesUnrelatedContent() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try await JSONConfigStore(fileURL: file)
            .apply(.set(path: "fileEditor.wordWrap", value: .bool(true)))

        #expect(result.installedValue(at: "fileEditor.wordWrap") == .bool(true))
        #expect((try value("fileEditor.wordWrap", in: file) as? NSNumber)?.boolValue == true)
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.4)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("// keep this comment"))
        #expect(text.contains("\"scroll.cycle\""))
    }

    @Test("toggle flips a configured boolean, then the schema default when absent")
    func toggleUsesConfiguredValueOrDefault() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)

        _ = try await store.apply(.toggle(path: "sidebar.showLog"))
        #expect((try value("sidebar.showLog", in: file) as? NSNumber)?.boolValue == false)
        _ = try await store.apply(.toggle(path: "sidebar.showLog"))
        #expect((try value("sidebar.showLog", in: file) as? NSNumber)?.boolValue == true)

        // fileEditor.wordWrap is absent and defaults to false, so the first
        // toggle turns it on.
        _ = try await store.apply(.toggle(path: "fileEditor.wordWrap"))
        #expect((try value("fileEditor.wordWrap", in: file) as? NSNumber)?.boolValue == true)
    }

    @Test("toggle refuses a non-boolean setting without writing")
    func toggleRefusesNonBoolean() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let before = try Data(contentsOf: file)
        await #expect(throws: CmuxSettingChangeError.notBoolean("terminal.scrollSpeed")) {
            _ = try await JSONConfigStore(fileURL: file).apply(.toggle(path: "terminal.scrollSpeed"))
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("cycle advances, wraps, and restarts from an unlisted value")
    func cycleAdvancesAndWraps() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let values: [CmuxSettingValue] = [.number(1.0), .number(1.4), .number(1.8)]

        _ = try await store.apply(.cycle(path: "terminal.scrollSpeed", values: values))
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.8)
        _ = try await store.apply(.cycle(path: "terminal.scrollSpeed", values: values))
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.0)

        _ = try await store.apply(.set(path: "terminal.scrollSpeed", value: .number(2.5)))
        _ = try await store.apply(.cycle(path: "terminal.scrollSpeed", values: values))
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.0)
    }

    @Test("cycle starts from the schema default when the key is absent")
    func cycleStartsFromDefault() async throws {
        let file = try fixture("{}\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // terminal.scrollSpeed defaults to 1.0, so the next entry is 1.4.
        _ = try await JSONConfigStore(fileURL: file)
            .apply(.cycle(path: "terminal.scrollSpeed", values: [.number(1.0), .number(1.4)]))
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.4)
    }

    @Test("unknown, structural, and malformed paths are refused")
    func refusesNonSettingPaths() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let before = try Data(contentsOf: file)

        await #expect(throws: CmuxSettingChangeError.unknownPath("terminal.scrollSpeeed")) {
            _ = try await store.apply(.set(path: "terminal.scrollSpeeed", value: .number(1)))
        }
        await #expect(throws: CmuxSettingChangeError.notASetting("actions.evil")) {
            _ = try await store.apply(.set(path: "actions.evil", value: .object(["type": .string("command")])))
        }
        await #expect(throws: CmuxSettingChangeError.unknownPath("terminal..scrollSpeed")) {
            _ = try await store.apply(.unset(path: "terminal..scrollSpeed"))
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("toggle and cycle start from the live value of a key cmux.json doesn't set")
    func liveValuesSeedToggleAndCycle() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        // The Settings window turned word wrap on and set scroll speed 1.8;
        // neither is in the file.
        let live = CmuxSettingLiveValues { path in
            switch path {
            case "fileEditor.wordWrap": return .bool(true)
            case "sidebar.showLog": return .bool(false)
            default: return nil
            }
        }

        _ = try await store.apply(.toggle(path: "fileEditor.wordWrap"), liveValues: live)
        #expect((try value("fileEditor.wordWrap", in: file) as? NSNumber)?.boolValue == false)

        // A key the file does set ignores the live value.
        _ = try await store.apply(.toggle(path: "sidebar.showLog"), liveValues: live)
        #expect((try value("sidebar.showLog", in: file) as? NSNumber)?.boolValue == false)

        let reading = try store.reading(at: "fileEditor.wordWrap", liveValues: live)
        #expect(reading.configured == .bool(false))
        #expect(reading.live == nil)
        _ = try await store.apply(.unset(path: "fileEditor.wordWrap"))
        let unset = try store.reading(at: "fileEditor.wordWrap", liveValues: live)
        #expect(unset.configured == nil)
        #expect(unset.live == .bool(true))
        #expect(unset.effective == .bool(true))
    }

    @Test("UserDefaults-backed settings are read in their cmux.json form")
    func userDefaultsLiveValues() throws {
        let suiteName = "cmux.settings.live-values.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let live = CmuxSettingLiveValues.userDefaults(suiteName: suiteName)

        #expect(live.value(at: "fileEditor.wordWrap") == nil)
        defaults.set(true, forKey: SettingCatalog().fileEditor.wordWrap.userDefaultsKey)
        #expect(live.value(at: "fileEditor.wordWrap") == .bool(true))
        #expect(live.value(at: "not.a.setting") == nil)
    }

    @Test("re-setting a fraction that is already stored is not a change")
    func resettingTheSameFractionIsUnchanged() async throws {
        let file = try fixture("{ \"terminal\": { \"scrollSpeed\": 1.4 } }\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let before = try Data(contentsOf: file)

        let result = try await JSONConfigStore(fileURL: file)
            .apply(.set(path: "terminal.scrollSpeed", value: .number(1.4)))

        #expect(result.receipts.allSatisfy { $0.before == $0.installed })
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("stored values that aren't in their cmux.json form are mapped or dropped")
    func storedValueMappings() {
        let schema = CmuxConfigSchemaPathLookup()
        func live(_ path: String, _ stored: Any) -> CmuxSettingValue? {
            CmuxSettingLiveValues.liveValue(for: path, storedJSON: stored, schema: schema)
        }
        #expect(live("fileEditor.wordWrap", true) == .bool(true))
        #expect(live("terminal.scrollSpeed", 1.8) == .number(1.8))
        #expect(live("app.minimalMode", "minimal") == .bool(true))
        #expect(live("app.minimalMode", "standard") == .bool(false))
        #expect(live("app.keepWorkspaceOpenWhenClosingLastSurface", true) == .bool(false))
        #expect(live("terminal.sessionContentMaxWidth", -1) == .bool(false))
        #expect(live("terminal.sessionContentMaxWidth", 980) == .number(980))
        // Lists and maps are often stored as text; never trust them.
        #expect(live("browser.hostsToOpenInEmbeddedBrowser", "example.com\nlocalhost") == nil)
        #expect(live("notifications.soundOverrides", "{}") == nil)
        // A stored type the schema doesn't allow is dropped.
        #expect(live("fileEditor.wordWrap", "yes") == nil)
    }

    /// Every UserDefaults-backed setting the live resolver would accept must
    /// store its value in cmux.json form. A key whose encoded default
    /// disagrees with the schema default (an inverted flag, a mode string)
    /// needs an entry in `storedValueMappings`, or toggle would start from
    /// the wrong value.
    @Test("catalog settings the live resolver accepts store their cmux.json form")
    func catalogLiveValuesMatchSchemaDefaults() {
        let schema = CmuxConfigSchemaPathLookup()
        var mismatches: [String] = []
        for key in SettingCatalog().all {
            guard CmuxSettingLiveValues.storedValueMappings[key.id] == nil,
                  let encodedDefault = key.jsonDefaultValue(),
                  let accepted = CmuxSettingLiveValues.liveValue(for: key.id, storedJSON: encodedDefault, schema: schema),
                  let schemaDefault = schema.defaultValue(at: key.id.split(separator: ".").map(String.init)),
                  !(schemaDefault is NSNull),
                  let expected = CmuxSettingValue(jsonObject: schemaDefault) else {
                continue
            }
            if !CmuxSettingChangePlanner.matches(accepted, expected) {
                mismatches.append("\(key.id): stored default \(accepted.jsonText), schema default \(expected.jsonText)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "; "))")
    }

    @Test("a typo under a map keyed by names stays an unknown path")
    func typoUnderNamedMapIsUnknown() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        await #expect(throws: CmuxSettingChangeError.unknownPath("workspaceGroups.byCwd.app.colr")) {
            _ = try await JSONConfigStore(fileURL: file)
                .apply(.set(path: "workspaceGroups.byCwd.app.colr", value: .string("#FFFFFF")))
        }
    }

    @Test("a key containing a dot is refused with an explicit reason")
    func refusesKeysContainingDots() async throws {
        let file = try fixture("""
        {
          "settingPresets": {
            "webGroup": { "workspaceGroups": { "byCwd": { "~/src/app.web": { "color": "#7A4FD8" } } } }
          },
          "workspaceGroups": { "byCwd": { "~/src/app": { "color": "#112233" } } }
        }

        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let before = try Data(contentsOf: file)

        // A byCwd key without a dot is an ordinary path.
        #expect(try store.reading(at: "workspaceGroups.byCwd.~/src/app.color").configured == .string("#112233"))

        // Split on every ".", this path only resolves if "~/src/app.web" is
        // one key, so the refusal names the dot instead of an unknown path.
        await #expect(throws: CmuxSettingChangeError.keyContainsDot("workspaceGroups.byCwd.~/src/app.web.color")) {
            _ = try await store.apply(.set(path: "workspaceGroups.byCwd.~/src/app.web.color", value: .string("#FFFFFF")))
        }
        #expect(throws: CmuxSettingChangeError.keyContainsDot("workspaceGroups.byCwd.~/src/app.web.color")) {
            _ = try store.reading(at: "workspaceGroups.byCwd.~/src/app.web.color")
        }
        await #expect(throws: CmuxSettingChangeError.keyContainsDot("workspaceGroups.byCwd.~/src/app.web.color")) {
            _ = try await store.apply(.preset(name: "webGroup"))
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(CmuxSettingChangeError.keyContainsDot("x").errorDescription?.contains("\".\"") == true)
    }

    @Test("fractional numbers are written the way they were typed")
    func fractionalNumbersKeepTheirShortForm() async throws {
        let file = try fixture("""
        {
          "settingPresets": { "fast": { "terminal": { "scrollSpeed": 1.8 } } }
        }

        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)

        _ = try await store.apply(.set(path: "terminal.scrollSpeed", value: .number(1.4)))
        var text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("1.4"))
        #expect(!text.contains("1.399"))

        _ = try await store.apply(.preset(name: "fast"))
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("1.800"))
        #expect(!text.contains("1.799"))
        #expect((try value("terminal.scrollSpeed", in: file) as? NSNumber)?.doubleValue == 1.8)

        #expect(CmuxSettingValue.number(1.4).jsonText == "1.4")
        #expect(CmuxSettingValue.number(-0.25).jsonText == "-0.25")
        #expect(CmuxSettingValue.number(2).jsonText == "2")
    }

    @Test("each change describes itself as the equivalent cmux config command")
    func commandLineDescriptions() {
        #expect(CmuxSettingChange.set(path: "terminal.scrollSpeed", value: .number(1.4)).commandLineDescription
            == "cmux config set terminal.scrollSpeed 1.4")
        #expect(CmuxSettingChange.toggle(path: "fileEditor.wordWrap").commandLineDescription
            == "cmux config toggle fileEditor.wordWrap")
        #expect(CmuxSettingChange.cycle(path: "app.appearance", values: [.string("light"), .string("dark")]).commandLineDescription
            == "cmux config cycle app.appearance \"light\" \"dark\"")
        #expect(CmuxSettingChange.unset(path: "terminal.scrollSpeed").commandLineDescription
            == "cmux config unset terminal.scrollSpeed")
        #expect(CmuxSettingChange.preset(name: "sidebar.quiet").commandLineDescription
            == "cmux config preset sidebar.quiet")
    }

    @Test("values the schema rejects are refused without writing")
    func refusesInvalidValues() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let before = try Data(contentsOf: file)
        let error = await #expect(throws: JSONConfigMutationError.self) {
            _ = try await JSONConfigStore(fileURL: file)
                .apply(.set(path: "terminal.scrollSpeed", value: .number(99)))
        }
        guard case .invalidCandidate(let issues)? = error else {
            Issue.record("expected invalidCandidate, got \(String(describing: error))")
            return
        }
        #expect(issues.contains { $0.path.contains("scrollSpeed") })
        await #expect(throws: JSONConfigMutationError.self) {
            _ = try await JSONConfigStore(fileURL: file)
                .apply(.set(path: "fileEditor.wordWrap", value: .string("yes")))
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("unset removes the key so the default applies")
    func unsetRemovesKey() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try await JSONConfigStore(fileURL: file).apply(.unset(path: "terminal.scrollSpeed"))
        #expect(result.installedValue(at: "terminal.scrollSpeed") == nil)
        #expect(try value("terminal.scrollSpeed", in: file) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("// keep this comment"))
    }

    @Test("a preset merges its settings in one write and leaves other keys alone")
    func presetMergesLeaves() async throws {
        let file = try fixture("""
        {
          "settingPresets": {
            "sidebar.quiet": {
              "sidebar": { "showPorts": false, "showPullRequests": false },
              "terminal": { "rendererRealization": { "maxWarmRenderers": 2 } }
            }
          },
          "sidebar": { "showLog": true, "showPorts": true },
          "terminal": { "rendererRealization": { "idleSeconds": 30 } }
        }

        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try await JSONConfigStore(fileURL: file).apply(.preset(name: "sidebar.quiet"))

        #expect(Set(result.receipts.map(\.path)) == [
            "sidebar.showPorts",
            "sidebar.showPullRequests",
            "terminal.rendererRealization.maxWarmRenderers",
        ])
        #expect((try value("sidebar.showPorts", in: file) as? NSNumber)?.boolValue == false)
        #expect((try value("sidebar.showPullRequests", in: file) as? NSNumber)?.boolValue == false)
        #expect((try value("sidebar.showLog", in: file) as? NSNumber)?.boolValue == true)
        #expect((try value("terminal.rendererRealization.maxWarmRenderers", in: file) as? NSNumber)?.intValue == 2)
        #expect((try value("terminal.rendererRealization.idleSeconds", in: file) as? NSNumber)?.intValue == 30)
    }

    @Test("trusted pack presets can be applied without persisting pack metadata")
    func presetOverrideMergesLeaves() async throws {
        let file = try fixture("""
        {
          "sidebar": { "showLog": true }
        }

        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let result = try await store.apply(
            .preset(name: "sidebar.quiet"),
            presetOverrides: [
                "sidebar.quiet": .object([
                    "sidebar": .object(["showPorts": .bool(false)])
                ])
            ]
        )

        #expect(result.receipts.map(\.path) == ["sidebar.showPorts"])
        #expect((try value("sidebar.showPorts", in: file) as? NSNumber)?.boolValue == false)
        #expect((try value("settingPresets.sidebar.quiet", in: file)) == nil)
    }

    @Test("a missing or structural preset is refused without writing")
    func presetRefusals() async throws {
        let file = try fixture("""
        {
          "settingPresets": {
            "sneaky": { "actions": { "x": { "type": "command", "command": "echo" } } },
            "empty": {},
            "hollow": { "sidebar": {} }
          }
        }

        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let before = try Data(contentsOf: file)
        await #expect(throws: CmuxSettingChangeError.unknownPreset("missing")) {
            _ = try await store.apply(.preset(name: "missing"))
        }
        await #expect(throws: CmuxSettingChangeError.notASetting("actions")) {
            _ = try await store.apply(.preset(name: "sneaky"))
        }
        await #expect(throws: CmuxSettingChangeError.invalidPreset("empty")) {
            _ = try await store.apply(.preset(name: "empty"))
        }
        // An empty nested object merges nothing; it must not replace the
        // whole sidebar section.
        await #expect(throws: CmuxSettingChangeError.invalidPreset("hollow")) {
            _ = try await store.apply(.preset(name: "hollow"))
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("command-line values parse as JSON or fall back to a string")
    func commandLineValueParsing() {
        #expect(CmuxSettingValue(commandLineArgument: "true") == .bool(true))
        #expect(CmuxSettingValue(commandLineArgument: "1.8") == .number(1.8))
        #expect(CmuxSettingValue(commandLineArgument: "\"dark\"") == .string("dark"))
        #expect(CmuxSettingValue(commandLineArgument: "dark") == .string("dark"))
        #expect(CmuxSettingValue(commandLineArgument: "null") == .null)
        #expect(CmuxSettingValue(commandLineArgument: "[\"ctrl+b\",\"c\"]") == .array([.string("ctrl+b"), .string("c")]))
        #expect(CmuxSettingValue(commandLineArgument: "2").jsonText == "2")
    }
}

@Suite("Setting readings")
struct CmuxSettingReadingTests {
    @Test("reports the configured value, the default, and the effective value")
    func readsConfiguredAndDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cmux.json")
        try Data("{ \"terminal\": { \"scrollSpeed\": 1.8 } }\n".utf8).write(to: file)
        let store = JSONConfigStore(fileURL: file)

        let configured = try store.reading(at: "terminal.scrollSpeed")
        #expect(configured.configured == .number(1.8))
        #expect(configured.defaultValue == .number(1.0))
        #expect(configured.effective == .number(1.8))

        let absent = try store.reading(at: "fileEditor.wordWrap")
        #expect(absent.configured == nil)
        #expect(absent.effective == .bool(false))

        #expect(throws: CmuxSettingChangeError.notASetting("actions")) {
            _ = try store.reading(at: "actions")
        }
    }
}
