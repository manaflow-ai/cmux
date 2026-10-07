import Foundation
import CmuxTerminalCore
import os
import Testing
@testable import CmuxTerminal

private final class HermesAliasDirectoryScanCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        state.withLock { $0 }
    }

    func recordScan() {
        state.withLock { $0 += 1 }
    }
}

private final class HermesAliasDirectoryTrackingFileManager: FileManager {
    private let trackedDirectoryPath: String
    private let scanCounter: HermesAliasDirectoryScanCounter

    init(
        trackedDirectoryURL: URL,
        scanCounter: HermesAliasDirectoryScanCounter
    ) {
        self.trackedDirectoryPath = trackedDirectoryURL.standardizedFileURL.path
        self.scanCounter = scanCounter
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.standardizedFileURL.path == trackedDirectoryPath {
            scanCounter.recordScan()
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

@Suite("Terminal surface command shims")
struct TerminalSurfaceCommandShimPermissionsTests {
    @Test("Install hardens group-writable managed directories")
    func installHardensGroupWritableManagedDirectories() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimPermissionsTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let parentDirectory = temporaryDirectory.appending(
            path: "cmux-cli-shims",
            directoryHint: .isDirectory
        )
        let surfaceId = UUID()
        let shimDirectory = parentDirectory.appending(path: surfaceId.uuidString, directoryHint: .isDirectory)
        let staleShim = shimDirectory.appending(path: "stale-agent", directoryHint: .notDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        for directory in [parentDirectory, shimDirectory] {
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        }
        try "stale\n".write(to: staleShim, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shim = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceId,
                rootDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        #expect(shim.directoryPath == shimDirectory.path)
        let claudeShim = try #require(shim.shim(named: "claude"))
        #expect(!fileManager.fileExists(atPath: staleShim.path))
        #expect(fileManager.isExecutableFile(atPath: claudeShim.executablePath))
        for directory in [parentDirectory, shimDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o700)
        }
    }

    @Test("Install skips a shim path under a non-sticky shared ancestor")
    func installSkipsNonStickySharedAncestor() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimSharedAncestorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = try makeClaudeWrapperDirectory(in: root)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: temporaryDirectory.path)

        let shims = TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: UUID(),
            rootDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        #expect(shims == nil)
    }

    @Test("Install skips a symlinked shim parent")
    func installSkipsSymlinkedShimParent() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimSymlinkParentTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let parentDirectory = temporaryDirectory.appending(
            path: "cmux-cli-shims",
            directoryHint: .isDirectory
        )
        let linkTarget = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        let wrapperDirectory = try makeClaudeWrapperDirectory(in: root)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [temporaryDirectory, linkTarget] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkTarget.path)
        try fileManager.createSymbolicLink(at: parentDirectory, withDestinationURL: linkTarget)

        let shims = TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: UUID(),
            rootDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        #expect(shims == nil)
        #expect(try fileManager.contentsOfDirectory(atPath: linkTarget.path).isEmpty)
        #expect(try posixPermissions(atPath: linkTarget.path) == 0o755)
    }

    @Test("Install skips a symlinked surface directory")
    func installSkipsSymlinkedSurfaceDirectory() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimSymlinkSurfaceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let parentDirectory = temporaryDirectory.appending(
            path: "cmux-cli-shims",
            directoryHint: .isDirectory
        )
        let surfaceId = UUID()
        let shimDirectory = parentDirectory.appending(path: surfaceId.uuidString, directoryHint: .isDirectory)
        let linkTarget = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        let wrapperDirectory = try makeClaudeWrapperDirectory(in: root)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [parentDirectory, linkTarget] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkTarget.path)
        try fileManager.createSymbolicLink(at: shimDirectory, withDestinationURL: linkTarget)

        let shims = TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: surfaceId,
            rootDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        #expect(shims == nil)
        #expect(try fileManager.contentsOfDirectory(atPath: linkTarget.path).isEmpty)
        #expect(try posixPermissions(atPath: linkTarget.path) == 0o755)
    }

    @Test("Claude integration toggle controls the per-surface shim")
    func claudeIntegrationToggleControlsPerSurfaceShim() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceClaudeShimToggleTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        for wrapperName in ["cmux-claude-wrapper", "cmux-codex-wrapper"] {
            let wrapper = wrapperDirectory.appending(path: wrapperName, directoryHint: .notDirectory)
            try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }

        let enabled = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        #expect(enabled.shim(named: "claude") != nil)
        #expect(enabled.shim(named: "codex") != nil)

        let disabled = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                enabledCommands: [.codex],
                fileManager: fileManager
            )
        )
        #expect(disabled.shim(named: "claude") == nil)
        let codexShim = try #require(disabled.shim(named: "codex"))
        #expect(fileManager.isExecutableFile(atPath: codexShim.executablePath))
        #expect(!fileManager.fileExists(
            atPath: URL(fileURLWithPath: disabled.directoryPath)
                .appending(path: "claude", directoryHint: .notDirectory)
                .path
        ))
    }

    /// `cmux claude-teams` needs a per-surface shim root it can validate in both
    /// toggle states. #13590 removed the Claude shim for integration-off surfaces
    /// and Teams refused every launch from them in 0.65.0 (#17571). The CLI side of
    /// this contract is tests/test_cli_claude_teams_integration_disabled.py.
    @Test("Claude Teams shim-root contract holds for both integration states", arguments: [true, false])
    func claudeTeamsShimRootContract(claudeIntegrationEnabled: Bool) throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceClaudeTeamsContractTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        for definition in TerminalSurfaceAgentCommandShimDefinition.bundled {
            let wrapper = wrapperDirectory.appending(path: definition.wrapperName, directoryHint: .notDirectory)
            try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }

        let policy = TerminalSurfaceSpawnPolicy(
            claudeHooksEnabled: claudeIntegrationEnabled,
            customClaudePath: nil,
            subagentNotificationEnvironmentKey: "CMUX_TEST_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            suppressSubagentNotifications: false,
            cursorHooksEnabled: true,
            geminiHooksEnabled: true,
            kiroHooksEnabled: true,
            kiroNotificationLevel: "all",
            ampHooksEnabled: true,
            shellIntegrationEnabled: false,
            watchGitStatusEnabled: false,
            showPullRequestsEnabled: false
        )
        let surfaceId = UUID()
        let shims = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceId,
                rootDirectory: root,
                enabledCommands: policy.enabledAgentCommandShims,
                fileManager: fileManager
            ),
            "a surface must get a shim directory whatever the Claude toggle"
        )
        let environment = TerminalSurface.agentCommandShimEnvironment(
            claudeIntegrationEnabled: policy.claudeHooksEnabled,
            agentCommandShims: shims
        )

        // The shape Teams validates before writing tmux: cmux-cli-shims/<surface id>.
        let agentRoot = try #require(environment["CMUX_AGENT_COMMAND_SHIM_ROOT"])
        let agentRootURL = URL(fileURLWithPath: agentRoot, isDirectory: true)
        #expect(agentRootURL.lastPathComponent == surfaceId.uuidString)
        #expect(agentRootURL.deletingLastPathComponent().lastPathComponent == "cmux-cli-shims")

        if claudeIntegrationEnabled {
            #expect(environment["CMUX_CLAUDE_INTEGRATION_DISABLED"] == "0")
            #expect(environment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] == agentRoot)
            let claudeShim = try #require(environment["CMUX_CLAUDE_WRAPPER_SHIM"])
            #expect(claudeShim == agentRootURL.appending(path: "claude", directoryHint: .notDirectory).path)
            #expect(fileManager.isExecutableFile(atPath: claudeShim))
        } else {
            #expect(environment["CMUX_CLAUDE_INTEGRATION_DISABLED"] == "1")
            #expect(environment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] == nil)
            #expect(environment["CMUX_CLAUDE_WRAPPER_SHIM"] == nil)
            #expect(!fileManager.fileExists(
                atPath: agentRootURL.appending(path: "claude", directoryHint: .notDirectory).path
            ))
        }
    }

    @Test("Claude integration flag is exported even without agent shims")
    func claudeIntegrationFlagWithoutAgentShims() {
        #expect(TerminalSurface.agentCommandShimEnvironment(
            claudeIntegrationEnabled: false,
            agentCommandShims: nil
        ) == ["CMUX_CLAUDE_INTEGRATION_DISABLED": "1"])
        #expect(TerminalSurface.agentCommandShimEnvironment(
            claudeIntegrationEnabled: true,
            agentCommandShims: nil
        ) == ["CMUX_CLAUDE_INTEGRATION_DISABLED": "0"])
    }

    @Test("Fallback preserves literal glob characters in PATH entries")
    func fallbackPreservesLiteralGlobCharactersInPathEntries() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimPathTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        let literalPathDirectory = root.appending(path: "literal-[z]", directoryHint: .isDirectory)
        let globMatchDirectory = root.appending(path: "literal-z", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, literalPathDirectory, globMatchDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shims = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        let shim = try #require(shims.shim(named: "claude"))

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wrapper.path)
        let expectedExecutable = literalPathDirectory.appending(path: "claude", directoryHint: .notDirectory)
        let globMatchedExecutable = globMatchDirectory.appending(path: "claude", directoryHint: .notDirectory)
        try "#!/bin/sh\nprintf 'literal-path\\n'\n".write(
            to: expectedExecutable,
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf 'glob-expanded-path\\n'\n".write(
            to: globMatchedExecutable,
            atomically: true,
            encoding: .utf8
        )
        for executable in [expectedExecutable, globMatchedExecutable] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(shim.directoryPath):\(literalPathDirectory.path):/usr/bin:/bin",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(data: data, encoding: .utf8) == "literal-path\n")
    }
    @Test("Official Hermes profile aliases route through the Hermes wrapper")
    func officialHermesProfileAliasesRouteThroughWrapper() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceHermesAliasTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let shadowDirectory = root.appending(path: "shadow", directoryHint: .isDirectory)
        let aliasDirectory = root.appending(path: ".local/bin", directoryHint: .isDirectory)
        let hermesWrapper = wrapperDirectory.appending(
            path: "cmux-hermes-agent-wrapper",
            directoryHint: .notDirectory
        )
        let officialAlias = aliasDirectory.appending(path: "coder", directoryHint: .notDirectory)
        let unrelatedCommand = aliasDirectory.appending(path: "other", directoryHint: .notDirectory)
        let shadowBash = shadowDirectory.appending(path: "bash", directoryHint: .notDirectory)
        let invocationLog = root.appending(path: "wrapper-args.log", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, shadowDirectory, aliasDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        #!/bin/bash
        printf '%s\\0' "$@" > "$CMUX_TEST_LOG"
        """.write(to: hermesWrapper, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exit 97
        """.write(to: shadowBash, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exec /opt/hermes/bin/hermes -p coder "$@"
        """.write(to: officialAlias, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exec /opt/tools/other -p coder "$@"
        """.write(to: unrelatedCommand, atomically: true, encoding: .utf8)
        for executable in [hermesWrapper, shadowBash, officialAlias, unrelatedCommand] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let shims = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                hermesProfileAliasDirectoryURL: aliasDirectory,
                fileManager: fileManager
            )
        )
        let aliasShim = try #require(shims.shim(named: "coder"))
        #expect(shims.shim(named: "other") == nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: aliasShim.executablePath)
        process.arguments = ["--continue", "doctor"]
        process.environment = [
            "PATH": "\(shadowDirectory.path):\(shims.directoryPath):/usr/bin:/bin",
            "CMUX_TEST_LOG": invocationLog.path,
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let arguments = try Data(contentsOf: invocationLog)
            .split(separator: 0)
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(arguments == ["-p", "coder", "--continue", "doctor"])
    }

    @Test("Hermes profile aliases avoid redundant scans and refresh retargeted files")
    func hermesProfileAliasesCacheUntilAnAliasFileChanges() async throws {
        let setupFileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceHermesAliasCatalogTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let aliasDirectory = root.appending(path: ".local/bin", directoryHint: .isDirectory)
        let hermesWrapper = wrapperDirectory.appending(
            path: "cmux-hermes-agent-wrapper",
            directoryHint: .notDirectory
        )
        let officialAlias = aliasDirectory.appending(path: "coder", directoryHint: .notDirectory)
        let invocationLog = root.appending(path: "wrapper-args.log", directoryHint: .notDirectory)
        defer { try? setupFileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, aliasDirectory] {
            try setupFileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        #!/usr/bin/env bash
        printf '%s\\0' "$@" > "$CMUX_TEST_LOG"
        """.write(to: hermesWrapper, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exec /opt/hermes/bin/hermes -p coder "$@"
        """.write(to: officialAlias, atomically: true, encoding: .utf8)
        for executable in [hermesWrapper, officialAlias] {
            try setupFileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let aliasDirectoryModificationDate = try #require(
            setupFileManager.attributesOfItem(atPath: aliasDirectory.path)[.modificationDate] as? Date
        )
        let scanCounter = HermesAliasDirectoryScanCounter()
        let catalogFileManager = HermesAliasDirectoryTrackingFileManager(
            trackedDirectoryURL: aliasDirectory,
            scanCounter: scanCounter
        )
        let catalog = HermesProfileAliasCatalog(
            wrapperDirectoryURL: aliasDirectory,
            fileManager: catalogFileManager
        )
        let first = try #require(
            await TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                hermesProfileAliasCatalog: catalog,
                fileManager: setupFileManager
            )
        )
        let firstAliasShim = try #require(first.shim(named: "coder"))
        #expect(
            try capturedArguments(
                from: firstAliasShim,
                logURL: invocationLog,
                workingDirectoryURL: root
            ) == ["-p", "coder", "--continue"]
        )
        #expect(scanCounter.value == 1)

        let cached = try #require(
            await TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                hermesProfileAliasCatalog: catalog,
                fileManager: setupFileManager
            )
        )
        let cachedAliasShim = try #require(cached.shim(named: "coder"))
        #expect(
            try capturedArguments(
                from: cachedAliasShim,
                logURL: invocationLog,
                workingDirectoryURL: root
            ) == ["-p", "coder", "--continue"]
        )
        #expect(scanCounter.value == 1)

        let updatedWrapper = """
        #!/bin/sh
        exec /opt/hermes/bin/hermes -p audit "$@"
        """
        try Data(updatedWrapper.utf8).write(to: officialAlias, options: [])
        try setupFileManager.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(2)],
            ofItemAtPath: officialAlias.path
        )
        try setupFileManager.setAttributes(
            [.modificationDate: aliasDirectoryModificationDate],
            ofItemAtPath: aliasDirectory.path
        )
        #expect(
            try capturedArguments(
                from: firstAliasShim,
                logURL: invocationLog,
                workingDirectoryURL: root
            ) == ["-p", "audit", "--continue"]
        )
        let refreshed = try #require(
            await TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                rootDirectory: temporaryDirectory,
                hermesProfileAliasCatalog: catalog,
                fileManager: setupFileManager
            )
        )
        let refreshedAliasShim = try #require(refreshed.shim(named: "coder"))
        #expect(
            try capturedArguments(
                from: refreshedAliasShim,
                logURL: invocationLog,
                workingDirectoryURL: root
            ) == ["-p", "audit", "--continue"]
        )
        #expect(scanCounter.value == 2)
    }

    private func makeClaudeWrapperDirectory(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return wrapperDirectory
    }

    private func posixPermissions(atPath path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    private func capturedArguments(
        from shim: TerminalSurfaceAgentCommandShim,
        logURL: URL,
        workingDirectoryURL: URL
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.arguments = ["--continue"]
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = [
            "PATH": "\(shim.directoryPath):/usr/bin:/bin",
            "CMUX_TEST_LOG": logURL.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: logURL)
            .split(separator: 0)
            .compactMap { String(data: $0, encoding: .utf8) }
    }
}
