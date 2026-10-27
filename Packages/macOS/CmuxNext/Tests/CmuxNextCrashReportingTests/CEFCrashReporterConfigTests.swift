import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-105: the crash_reporter.cfg embed-cef.sh writes for a Crashpad build is parsed as CEF parses
/// it, and cmux forwards dumps only from a config with no ServerURL.
@Suite struct CEFCrashReporterConfigTests {
    /// The file write-crash-reporter-cfg.sh writes with CMUX_NEXT_CEF_CRASHPAD=1.
    static let embedded = """
    # Written by scripts/cmux-next/write-crash-reporter-cfg.sh (p09-observability-105).
    # No ServerURL: Crashpad keeps reports on disk and never uploads them.
    [Config]
    ProductName=cmux-next
    ProductVersion=0.62.0+4711 cef154.0.8037.98-30
    BrowserCrashForwardingEnabled=true
    MaxDatabaseSizeInMb=50
    MaxDatabaseAgeInDays=7
    """

    @Test func theEmbeddedConfigHasNoServerURL() throws {
        let config = CEFCrashReporterConfig(text: Self.embedded)
        #expect(config.serverURL == nil)
        #expect(config.config["ProductName"] == "cmux-next")
        let ver = try #require(config.config["ProductVersion"])
        #expect(ChromiumMinidump.isPlainValue(ver), "the annotation survives redaction")
        #expect(ChromiumMinidump.CrashedBuild(ver: ver)?.build == "4711")
        #expect(config.config["BrowserCrashForwardingEnabled"] == "true")
        #expect(config.crashKeys.isEmpty)
    }

    @Test func sectionsCommentsAndWhitespaceParseAsCEFDoes() {
        let config = CEFCrashReporterConfig(text: """
        ServerURL=https://outside.example/ignored
        [Other]
        ServerURL=https://other.example/ignored
          [Config]
          ServerURL = https://crash.example/upload
        # ServerURL=https://comment.example/
        [CrashKeys]
        cmux_state = small
        """)
        #expect(config.serverURL == "https://crash.example/upload")
        #expect(config.crashKeys == ["cmux_state": "small"])
    }

    @Test func dumpsAreForwardedOnlyFromAConfigWithoutServerURL() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-crash-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chromium = root.appending(path: "Chromium", directoryHint: .isDirectory)
        let moved = root.appending(path: "Dumps", directoryHint: .isDirectory)
        let none: [String: String] = [:]
        #expect(CEFCrashReporterConfig.minidumpDatabase(resources: root, chromiumRoot: chromium, environment: none) == nil,
                "no config, no Crashpad")
        try Data(Self.embedded.utf8).write(to: root.appending(path: CEFCrashReporterConfig.fileName))
        #expect(CEFCrashReporterConfig.minidumpDatabase(resources: root, chromiumRoot: chromium, environment: none) == chromium,
                "CEF keeps dumps in root_cache_path (DIR_CRASH_DUMPS)")
        let override = [CEFCrashReporterConfig.dumpLocationKey: moved.path]
        #expect(CEFCrashReporterConfig.minidumpDatabase(resources: root, chromiumRoot: chromium, environment: override)?.path
                == moved.path)
        try Data((Self.embedded + "\nServerURL=https://crash.example/upload\n").utf8)
            .write(to: root.appending(path: CEFCrashReporterConfig.fileName))
        #expect(CEFCrashReporterConfig.minidumpDatabase(resources: root, chromiumRoot: chromium, environment: none) == nil,
                "a config that uploads by itself is never forwarded")
    }
}
