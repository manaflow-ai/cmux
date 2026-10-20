import Darwin
import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

@MainActor
@Suite("Ghostty security defaults", .serialized)
struct GhosttySecurityDefaultsTests {
    @Test(arguments: ["", "clipboard-write = allow\n", "clipboard-write = ask\n"])
    func programClipboardWritesRequireConsent(_ text: String) throws {
        #expect(try resolvedString("clipboard-write", configText: text) == "ask")
    }

    @Test func explicitClipboardWriteDenyStaysDenied() throws {
        #expect(try resolvedString("clipboard-write", configText: "clipboard-write = deny\n") == "deny")
    }

    private func resolvedString(_ key: String, configText: String) throws -> String? {
        try withConfig(configText) { config in
            var value: UnsafePointer<CChar>?
            let found = GhosttyRuntime.configGet(config, &value, key: key)
            #expect(found)
            return value.map { String(cString: $0) }
        }
    }

    private func withConfig<T>(_ text: String, read: (ghostty_config_t) throws -> T) throws -> T {
        _ = GhosttyRuntime.shared // ghostty_config_new requires ghostty_init
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        let key = GhosttyRuntime.configOverrideKey
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, file.path, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity))
        defer { ghostty_config_free(config) }
        return try read(config)
    }
}
