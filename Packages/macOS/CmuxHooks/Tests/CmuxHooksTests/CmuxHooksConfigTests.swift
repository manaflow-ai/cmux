import Foundation
import Testing

@testable import CmuxHooks

@Suite
struct CmuxHooksConfigTests {
    @Test
    func decodesFullConfigDefaultsAndClamps() throws {
        let json = """
        {
          "preSpawn": { "command": " /bin/gate ", "unknown": true },
          "events": {
            "workspace.created": [
              { "command": "./notify.sh", "args": ["${event.payload.cwd}"], "timeoutMs": 9999999, "enabled": false },
              { "command": "/bin/echo", "timeoutMs": 20 }
            ]
          }
        }
        """
        let config = try JSONDecoder().decode(CmuxHooksConfig.self, from: Data(json.utf8))
        #expect(config.preSpawn?.command == "/bin/gate")
        #expect(config.preSpawn?.args == [])
        #expect(config.preSpawn?.timeoutMs == 5_000)
        #expect(config.preSpawn?.enabled == true)
        let hooks = try #require(config.events["workspace.created"])
        #expect(hooks[0].timeoutMs == 600_000)
        #expect(hooks[0].enabled == false)
        #expect(hooks[1].timeoutMs == 100)
        #expect(hooks[1].enabled == true)
    }

    @Test
    func blankCommandThrows() throws {
        let json = #"{"preSpawn":{"command":"   "}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CmuxHooksConfig.self, from: Data(json.utf8))
        }
    }

    @Test
    func loaderStates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let loader = CmuxHooksConfigLoader()

        #expect(loader.load(fileURL: file) == .absent)

        try #"{"app":{}}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(loader.load(fileURL: file) == .absent)

        try #"{ "hooks": { "preSpawn": { "command": "/bin/true" } } }"#.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        if case .loaded(let config) = loader.load(fileURL: file) {
            #expect(config.preSpawn?.command == "/bin/true")
        } else {
            Issue.record("expected loaded hooks config")
        }

        try #"{ "hooks": { "preSpawn": { "command": " " } } }"#.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        if case .broken = loader.load(fileURL: file) {} else {
            Issue.record("expected broken hooks config")
        }

        try #"{ "hooks": "#.write(to: file, atomically: true, encoding: .utf8)
        if case .broken = loader.load(fileURL: file) {} else {
            Issue.record("expected broken syntax with textual hooks")
        }

        try #"{ "app": "#.write(to: file, atomically: true, encoding: .utf8)
        #expect(loader.load(fileURL: file) == .absent)
    }

    @Test
    func loaderToleratesJSONC() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-jsonc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try """
        {
          // user hook
          "hooks": {
            "preSpawn": { "command": "/bin/true", },
          },
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        if case .loaded(let config) = CmuxHooksConfigLoader().load(fileURL: file) {
            #expect(config.preSpawn?.command == "/bin/true")
        } else {
            Issue.record("expected JSONC hooks config to load")
        }
    }
}
