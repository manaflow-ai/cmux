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

private final class CancelAfterFirstShimFileManager: FileManager {
    private let didCancel = OSAllocatedUnfairLock(initialState: false)
    private let removalAttempts = OSAllocatedUnfairLock(initialState: 0)

    var removalAttemptCount: Int { removalAttempts.withLock { $0 } }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        let commandName = URL(fileURLWithPath: path).lastPathComponent
        guard ["claude", "codex", "hermes"].contains(commandName) else { return }
        let shouldCancel = didCancel.withLock { cancelled in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        if shouldCancel {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
    }

    override func removeItem(at url: URL) throws {
        let attempt = removalAttempts.withLock { attempts in
            attempts += 1
            return attempts
        }
        if attempt < 3 {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}

@Suite("Terminal surface command shims")
struct TerminalSurfaceCommandShimPermissionsTests {
    @Test("Cancellation removes a partial per-surface shim directory")
    func cancellationRemovesPartialShimDirectory() async throws {
        let setupFileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimCancellationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let aliasDirectory = root.appending(path: "aliases", directoryHint: .isDirectory)
        let surfaceID = UUID()
        let shimParentDirectory = temporaryDirectory
            .appending(path: "cmux-cli-shims", directoryHint: .isDirectory)
        defer { try? setupFileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, aliasDirectory] {
            try setupFileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        for wrapperName in ["cmux-claude-wrapper", "cmux-codex-wrapper"] {
            let wrapper = wrapperDirectory.appending(
                path: wrapperName,
                directoryHint: .notDirectory
            )
            try "#!/bin/sh\nexit 0\n".write(
                to: wrapper,
                atomically: true,
                encoding: .utf8
            )
            try setupFileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: wrapper.path
            )
        }

        let fileManager = CancelAfterFirstShimFileManager()
        let installTask = Task {
            await TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceID,
                temporaryDirectory: temporaryDirectory,
                hermesProfileAliasCatalog: HermesProfileAliasCatalog(
                    wrapperDirectoryURL: aliasDirectory
                ),
                fileManager: fileManager
            )
        }
        let result = await installTask.value

        #expect(result == nil)
        #expect(fileManager.removalAttemptCount == 3)
        let remainingShimDirectories = (
            try? setupFileManager.contentsOfDirectory(
                at: shimParentDirectory,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        #expect(remainingShimDirectories.isEmpty)
    }

    @Test("Cancelled reinstall preserves the current per-surface shim directory")
    func cancelledReinstallPreservesCurrentShimDirectory() async throws {
        let setupFileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimReinstallTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let aliasDirectory = root.appending(path: "aliases", directoryHint: .isDirectory)
        let surfaceID = UUID()
        defer { try? setupFileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, aliasDirectory] {
            try setupFileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        for wrapperName in ["cmux-claude-wrapper", "cmux-codex-wrapper"] {
            let wrapper = wrapperDirectory.appending(
                path: wrapperName,
                directoryHint: .notDirectory
            )
            try "#!/bin/sh\nexit 0\n".write(
                to: wrapper,
                atomically: true,
                encoding: .utf8
            )
            try setupFileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: wrapper.path
            )
        }
        let current = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceID,
                temporaryDirectory: temporaryDirectory,
                fileManager: setupFileManager
            )
        )

        let replacement = await TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: surfaceID,
            temporaryDirectory: temporaryDirectory,
            hermesProfileAliasCatalog: HermesProfileAliasCatalog(
                wrapperDirectoryURL: aliasDirectory
            ),
            fileManager: CancelAfterFirstShimFileManager()
        )

        #expect(replacement == nil)
        #expect(setupFileManager.fileExists(atPath: current.directoryPath))
        for shim in current.shims {
            #expect(setupFileManager.isExecutableFile(atPath: shim.executablePath))
        }
    }

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
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: parentDirectory.path)
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shim = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceId,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        let replacement = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceId,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        let shimDirectory = URL(fileURLWithPath: shim.directoryPath, isDirectory: true)
        #expect(
            shimDirectory.deletingLastPathComponent().standardizedFileURL
                == parentDirectory.standardizedFileURL
        )
        #expect(
            shimDirectory.lastPathComponent.hasPrefix(
                "v1-p\(ProcessInfo.processInfo.processIdentifier)-\(surfaceId.uuidString)-"
            )
        )
        #expect(replacement.directoryPath != shim.directoryPath)
        for directory in [parentDirectory, shimDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o700)
        }
    }

    @Test("Install sweep removes only old owned directories from dead processes")
    func installSweepRemovesOnlyOldOwnedDirectoriesFromDeadProcesses() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimSweepTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let parentDirectory = root.appending(
            path: "cmux-cli-shims",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let surfaceID = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let currentProcessID: Int32 = 40_001
        let deadProcessID: Int32 = 40_002
        let liveProcessID: Int32 = 40_003
        let recentDeadProcessID: Int32 = 40_004
        func directory(processID: Int32) -> URL {
            parentDirectory.appending(
                path: "v1-p\(processID)-\(surfaceID.uuidString)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        }
        let staleDeadDirectory = directory(processID: deadProcessID)
        let staleLiveDirectory = directory(processID: liveProcessID)
        let recentDeadDirectory = directory(processID: recentDeadProcessID)
        let malformedDirectory = parentDirectory.appending(
            path: "v1-p\(deadProcessID)-not-a-managed-directory",
            directoryHint: .isDirectory
        )
        for directory in [
            staleDeadDirectory,
            staleLiveDirectory,
            recentDeadDirectory,
            malformedDirectory,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        for directory in [staleDeadDirectory, staleLiveDirectory, malformedDirectory] {
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-120)],
                ofItemAtPath: directory.path
            )
        }
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: recentDeadDirectory.path
        )
        let parentAttributes = try fileManager.attributesOfItem(atPath: parentDirectory.path)
        let ownerUserID = try #require(parentAttributes[.ownerAccountID] as? NSNumber)

        TerminalSurface.removeStaleAgentCommandShimDirectories(
            in: parentDirectory,
            ownerProcessID: currentProcessID,
            ownerUserID: ownerUserID.uint32Value,
            now: now,
            minimumAge: 60,
            maximumEntryCount: 256,
            isCancelled: { false },
            isProcessAlive: { $0 == liveProcessID },
            fileManager: fileManager
        )

        #expect(!fileManager.fileExists(atPath: staleDeadDirectory.path))
        #expect(fileManager.fileExists(atPath: staleLiveDirectory.path))
        #expect(fileManager.fileExists(atPath: recentDeadDirectory.path))
        #expect(fileManager.fileExists(atPath: malformedDirectory.path))
    }

    @Test("Stale cleanup owner claims one pass per temporary root")
    func staleCleanupOwnerClaimsOnePassPerTemporaryRoot() {
        let owner = TerminalSurfaceAgentCommandShimStaleCleanupOwner()
        let firstRoot = URL(fileURLWithPath: "/tmp/cmux-shim-cleanup-a", isDirectory: true)
        let equivalentFirstRoot = firstRoot.appending(path: "..", directoryHint: .isDirectory)
            .appending(path: firstRoot.lastPathComponent, directoryHint: .isDirectory)
        let secondRoot = URL(fileURLWithPath: "/tmp/cmux-shim-cleanup-b", isDirectory: true)

        #expect(owner.claim(firstRoot))
        #expect(!owner.claim(equivalentFirstRoot))
        #expect(owner.claim(secondRoot))
    }

    @Test("Stale cleanup pass honors entry and cancellation bounds")
    func staleCleanupPassHonorsEntryAndCancellationBounds() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimSweepBoundsTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for processID in [50_001, 50_002, 50_003] {
            let directory = root.appending(
                path: "v1-p\(processID)-\(UUID().uuidString)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-120)],
                ofItemAtPath: directory.path
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: root.path)
        let ownerUserID = try #require(attributes[.ownerAccountID] as? NSNumber)

        TerminalSurface.removeStaleAgentCommandShimDirectories(
            in: root,
            ownerProcessID: 50_000,
            ownerUserID: ownerUserID.uint32Value,
            now: now,
            minimumAge: 60,
            maximumEntryCount: 1,
            isCancelled: { false },
            isProcessAlive: { _ in false },
            fileManager: fileManager
        )
        let afterBoundedPass = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(afterBoundedPass.count == 2)

        TerminalSurface.removeStaleAgentCommandShimDirectories(
            in: root,
            ownerProcessID: 50_000,
            ownerUserID: ownerUserID.uint32Value,
            now: now,
            minimumAge: 60,
            maximumEntryCount: 64,
            isCancelled: { true },
            isProcessAlive: { _ in false },
            fileManager: fileManager
        )
        let afterCancelledPass = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(afterCancelledPass.count == 2)
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
                temporaryDirectory: temporaryDirectory,
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
                temporaryDirectory: temporaryDirectory,
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
                temporaryDirectory: temporaryDirectory,
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
                temporaryDirectory: temporaryDirectory,
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
                temporaryDirectory: temporaryDirectory,
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
