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

    @Test("values the schema rejects are refused without writing")
    func refusesInvalidValues() async throws {
        let file = try fixture(baseConfig)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let before = try Data(contentsOf: file)
        await #expect {
            _ = try await JSONConfigStore(fileURL: file)
                .apply(.set(path: "terminal.scrollSpeed", value: .number(99)))
        } throws: { error in
            guard case JSONConfigMutationError.invalidCandidate(let issues) = error else { return false }
            return issues.contains { $0.path.contains("scrollSpeed") }
        }
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

    @Test("a missing or structural preset is refused without writing")
    func presetRefusals() async throws {
        let file = try fixture("""
        {
          "settingPresets": {
            "sneaky": { "actions": { "x": { "type": "command", "command": "echo" } } },
            "empty": {}
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
