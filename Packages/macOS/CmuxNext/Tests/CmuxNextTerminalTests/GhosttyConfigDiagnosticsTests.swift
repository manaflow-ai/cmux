import Foundation
import Testing
@testable import CmuxNextTerminal

/// R92 diagnostics: a key cmux does not apply that the user set in a
/// Ghostty file is reported with its file, line and reason, also from an
/// include; keys cmux applies and keys left at their default are not; a line
/// libghostty cannot read is reported as invalid.
@MainActor @Suite(.serialized) struct GhosttyConfigDiagnosticsTests {
    /// libghostty needs `ghostty_init` (the shared runtime) before configs.
    init() { _ = GhosttyRuntime.shared }

    @Test func unsupportedKeysFromTheUsersFilesAreReportedWithTheirSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "config")
        let extra = directory.appending(path: "extra")
        try Data("""
        font-size = 13
        window-decoration = none
        # quick-terminal-size = 50%
        quick-terminal-position = top
        bogus-key-for-a-test = 1
        config-file = extra

        """.utf8).write(to: config)
        try Data("macos-hidden = always\n".utf8).write(to: extra)
        let configPath = config.resolvingSymlinksInPath().path
        let extraPath = extra.resolvingSymlinksInPath().path

        let report = GhosttyRuntime.configDiagnostics(configFile: config.path)
        let keys = report.filter { $0.kind == .key }
        func resolved(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        #expect(keys.map(\.name) == ["window-decoration", "quick-terminal-position", "macos-hidden"],
                "in load order; font-size applies, the commented key is unset")
        let decoration = try #require(keys.first)
        #expect(resolved(decoration.file) == configPath && decoration.line == 2)
        #expect(decoration.support == GhosttyUnsupported(.superseded, replacement: "window.titlebar"))
        #expect(keys[1].support?.reason == .later && keys[1].line == 4)
        #expect(resolved(keys[2].file) == extraPath && keys[2].line == 1 && keys[2].support?.reason == .notApplicable)
        let invalid = report.filter { $0.kind == .invalid }
        #expect(invalid.contains { $0.name.contains("bogus-key-for-a-test") }, "\(invalid.map(\.name))")
    }
}
