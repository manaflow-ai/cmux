import Foundation
import Testing
@testable import CMUX_Surface_Status_Sidebar

struct SurfaceStatusTests {
    private func fixture() throws -> (root: URL, home: URL, state: URL, manager: SurfaceStatusAdapterManager) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "surface-status-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let state = home.appending(path: ".state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let payloads = [
            SurfaceStatusAdapterPayload(
                id: "pi",
                resourceName: "pi",
                resourceExtension: "ts",
                destinationComponents: [".pi", "agent", "extensions", "cmux-sidebar-agent-status.ts"],
                bytes: Data("pi payload\n".utf8)
            ),
            SurfaceStatusAdapterPayload(
                id: "opencode",
                resourceName: "opencode",
                resourceExtension: "mjs",
                destinationComponents: [".config", "opencode", "plugins", "cmux-sidebar-agent-status.js"],
                bytes: Data("opencode payload\n".utf8)
            ),
        ]
        return (root, home, state, try SurfaceStatusAdapterManager(
            homeDirectory: home,
            stateDirectory: state,
            payloads: payloads
        ))
    }

    @Test func useInCmuxSelectionWritesExpectedHostPreferences() throws {
        let suiteName = "surface-status-cmux-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try SurfaceStatusCmuxSelection.apply(defaults: defaults)

        #expect(SurfaceStatusCmuxSelection.isApplied(defaults: defaults))
    }

    @Test func installDisableEnableAndUninstallOwnOnlyManagedFiles() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unrelated = fixture.home.appending(path: ".pi/agent/extensions/herdr-agent-state.ts")
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("herdr\n".utf8).write(to: unrelated)

        var inspection = try fixture.manager.apply(.install)
        #expect(inspection.adapters.allSatisfy { $0.state == .enabled })
        #expect(inspection.receiptPresent)
        #expect((try? Data(contentsOf: unrelated)) == Data("herdr\n".utf8))

        inspection = try fixture.manager.apply(.disable)
        #expect(inspection.adapters.allSatisfy { $0.state == .disabled })
        inspection = try fixture.manager.apply(.install)
        #expect(inspection.adapters.allSatisfy { $0.state == .enabled })
        inspection = try fixture.manager.apply(.disable)
        #expect(inspection.adapters.allSatisfy { $0.state == .disabled })
        inspection = try fixture.manager.apply(.enable)
        #expect(inspection.adapters.allSatisfy { $0.state == .enabled })
        inspection = try fixture.manager.apply(.uninstall)
        #expect(inspection.adapters.allSatisfy { $0.state == .notInstalled })
        #expect(!inspection.receiptPresent)
        #expect((try? Data(contentsOf: unrelated)) == Data("herdr\n".utf8))
    }

    @Test func modifiedOwnedFileIsPreservedOnUninstall() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.manager.apply(.install)
        let destination = fixture.manager.destination(for: fixture.manager.payloads[0])
        try Data("user modified\n".utf8).write(to: destination, options: .atomic)

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try fixture.manager.apply(.uninstall)
        }
        #expect((try? String(contentsOf: destination, encoding: .utf8)) == "user modified\n")
        #expect(FileManager.default.fileExists(atPath: fixture.manager.receiptURL.path))
    }

    @Test func unmanagedDestinationIsPreservedAndNoReceiptIsCreated() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.manager.destination(for: fixture.manager.payloads[0])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("user-owned adapter\n".utf8)
        try bytes.write(to: destination)

        let inspection = try fixture.manager.inspect()
        #expect(inspection.adapters.first { $0.id == "pi" }?.state == .unmanaged)
        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try fixture.manager.apply(.install)
        }
        #expect((try? Data(contentsOf: destination)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.manager.receiptURL.path))
    }

    @Test func symlinkedManagerLockIsRejected() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let sentinel = fixture.home.appending(path: "lock-sentinel")
        try Data("keep\n".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinel.path)
        try FileManager.default.createSymbolicLink(at: fixture.state.appending(path: "manager.lock"), withDestinationURL: sentinel)

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try fixture.manager.apply(.install)
        }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: sentinel.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o644)
        #expect((try? String(contentsOf: sentinel, encoding: .utf8)) == "keep\n")
    }

    @Test func hardLinkedAdapterDestinationIsRejected() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.manager.destination(for: fixture.manager.payloads[0])
        let alias = fixture.home.appending(path: "adapter-hard-link")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy\n".utf8).write(to: destination)
        try FileManager.default.linkItem(at: destination, to: alias)

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try fixture.manager.inspect()
        }
        #expect((try? String(contentsOf: alias, encoding: .utf8)) == "legacy\n")
    }

    @Test func receiptUsesOneNativeSchema() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.manager.apply(.install)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            SurfaceStatusAdapterReceipt.self,
            from: Data(contentsOf: fixture.manager.receiptURL)
        )
        #expect(receipt.schemaVersion == 1)
        #expect(Set(receipt.records.map(\.id)) == Set(["pi", "opencode"]))
        #expect(try fixture.manager.inspect().adapters.allSatisfy { $0.state == .enabled })
    }

    @Test func bundledPayloadsAreAvailableInTheBuiltApp() throws {
        let payloads = try SurfaceStatusAdapterManager.bundledPayloads()
        #expect(Set(payloads.map(\.id)) == Set(["pi", "opencode"]))
        #expect(payloads.allSatisfy { !$0.bytes.isEmpty })
    }

    @Test func integrationManagerOwnsOnlyCodexLaunchPresenceArtifacts() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let zshrc = fixture.home.appending(path: ".zshrc")
        let hooks = fixture.home.appending(path: ".codex/hooks.json")
        try Data("export KEEP=1\n".utf8).write(to: zshrc)
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nativeHooks = Data(#"{"hooks":{"SessionStart":[{"hooks":[{"command":"native cmux hook"}]}]}}"#.utf8)
        try nativeHooks.write(to: hooks)
        let manager = try SurfaceStatusIntegrationManager(
            homeDirectory: fixture.home,
            stateDirectory: fixture.state,
            standardPayloads: fixture.manager.payloads,
            codexPresenceLauncherBytes: Data("#!/usr/bin/env python3\n".utf8),
            codexPresenceSnippetBytes: Data("function codex() { command helper; }\n".utf8)
        )

        var inspection = try manager.apply(.install)
        #expect(Set(inspection.adapters.map(\.id)) == Set(["pi", "opencode", "codex"]))
        #expect(try String(contentsOf: zshrc, encoding: .utf8).contains(SurfaceStatusCodexPresenceManager.sourceBlock))
        #expect(try Data(contentsOf: hooks) == nativeHooks)
        inspection = try manager.apply(.uninstall)
        #expect(inspection.adapters.allSatisfy { $0.state == .notInstalled })
        #expect(try Data(contentsOf: zshrc) == Data("export KEEP=1\n".utf8))
        #expect(try Data(contentsOf: hooks) == nativeHooks)
    }

    @Test func bundledCodexPresenceLauncherPreservesArgumentsAndSearchesPastCmuxShim() throws {
        let launcherURL = try #require(Bundle.main.url(
            forResource: "codex-presence-launcher",
            withExtension: "py",
            subdirectory: "AdapterPayloads"
        ) ?? Bundle.main.url(forResource: "codex-presence-launcher", withExtension: "py"))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "surface-status-codex-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let shimDirectory = root.appending(path: "cmux-cli-shims/surface", directoryHint: .isDirectory)
        let realDirectory = root.appending(path: "custom-bin", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let shim = shimDirectory.appending(path: "codex")
        let real = realDirectory.appending(path: "codex")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: shim)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [launcherURL.path, "--model", "test model", "--flag=value"]
        process.environment = [
            "HOME": home.path,
            "PATH": "\(shimDirectory.path):\(realDirectory.path)",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(lines == ["--model", "test model", "--flag=value"])
    }

    @Test func codexPresenceUninstallPreservesPreexistingEmptyZshrc() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let zshrc = fixture.home.appending(path: ".zshrc")
        try Data().write(to: zshrc)
        let manager = try SurfaceStatusIntegrationManager(
            homeDirectory: fixture.home,
            stateDirectory: fixture.state,
            standardPayloads: fixture.manager.payloads,
            codexPresenceLauncherBytes: Data("#!/usr/bin/env python3\n".utf8),
            codexPresenceSnippetBytes: Data("function codex() { command helper; }\n".utf8)
        )

        _ = try manager.apply(.install)
        _ = try manager.apply(.uninstall)

        #expect(FileManager.default.fileExists(atPath: zshrc.path))
        #expect(try Data(contentsOf: zshrc).isEmpty)
    }

    @Test func aggregateFailureRollsBackStandardAdapters() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try SurfaceStatusIntegrationManager(
            homeDirectory: fixture.home,
            stateDirectory: fixture.state,
            standardPayloads: fixture.manager.payloads,
            codexPresenceLauncherBytes: Data("#!/usr/bin/env python3\n".utf8),
            codexPresenceSnippetBytes: Data("function codex() { command helper; }\n".utf8)
        )
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let lockSentinel = fixture.home.appending(path: "codex-lock-sentinel")
        try Data("preserve\n".utf8).write(to: lockSentinel)
        try FileManager.default.createSymbolicLink(
            at: fixture.state.appending(path: "codex-presence-manager.lock"),
            withDestinationURL: lockSentinel
        )

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try manager.apply(.install)
        }
        for payload in fixture.manager.payloads {
            #expect(!FileManager.default.fileExists(atPath: fixture.manager.destination(for: payload).path))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.manager.receiptURL.path))
        #expect(!FileManager.default.fileExists(atPath: manager.codexPresenceManager.launcherURL.path))
        #expect((try? Data(contentsOf: lockSentinel)) == Data("preserve\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "integration-transaction.json").path))
    }

    @Test func aggregatePreflightRejectsCodexDriftBeforeStandardMutation() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try SurfaceStatusIntegrationManager(
            homeDirectory: fixture.home,
            stateDirectory: fixture.state,
            standardPayloads: fixture.manager.payloads,
            codexPresenceLauncherBytes: Data("#!/usr/bin/env python3\n".utf8),
            codexPresenceSnippetBytes: Data("function codex() { command helper; }\n".utf8)
        )
        try FileManager.default.createDirectory(
            at: manager.codexPresenceManager.launcherURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unmanaged = Data("user helper\n".utf8)
        try unmanaged.write(to: manager.codexPresenceManager.launcherURL)

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try manager.apply(.install)
        }
        for payload in fixture.manager.payloads {
            #expect(!FileManager.default.fileExists(atPath: fixture.manager.destination(for: payload).path))
        }
        #expect((try? Data(contentsOf: manager.codexPresenceManager.launcherURL)) == unmanaged)
    }

    @Test func newerPayloadUpgradesAnOwnedPreviousVersion() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.manager.apply(.install)
        let updatedPayloads = fixture.manager.payloads.map { payload in
            var bytes = payload.bytes
            bytes.append(Data("updated\n".utf8))
            return SurfaceStatusAdapterPayload(
                id: payload.id,
                resourceName: payload.resourceName,
                resourceExtension: payload.resourceExtension,
                destinationComponents: payload.destinationComponents,
                bytes: bytes
            )
        }
        let updated = try SurfaceStatusAdapterManager(
            homeDirectory: fixture.home,
            stateDirectory: fixture.state,
            payloads: updatedPayloads
        )
        #expect(try updated.inspect().adapters.allSatisfy { $0.state == .updateAvailable })
        let inspection = try updated.apply(.install)
        #expect(inspection.adapters.allSatisfy { $0.state == .enabled })
        for payload in updatedPayloads {
            #expect((try? Data(contentsOf: updated.destination(for: payload))) == payload.bytes)
        }
    }

    @Test func incompleteTransactionIsRecoveredBeforeInspection() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.manager.destination(for: fixture.manager.payloads[0])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial\n".utf8).write(to: destination)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "transactionID": UUID().uuidString,
            "snapshots": [
                ["id": "receipt", "existed": false],
                ["id": "pi", "existed": false],
                ["id": "opencode", "existed": false],
            ],
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: fixture.state.appending(path: "transaction.json"))
        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            try fixture.manager.recoverIncompleteTransaction()
        }
        #expect((try? String(contentsOf: destination, encoding: .utf8)) == "partial\n")
        #expect(FileManager.default.fileExists(atPath: fixture.state.appending(path: "transaction.json").path))
    }

    @Test func symlinkedAdapterDirectoryIsRejected() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let realDirectory = fixture.home.appending(path: "real-pi", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".pi"),
            withDestinationURL: realDirectory
        )

        #expect(throws: SurfaceStatusAdapterManagerError.self) {
            _ = try fixture.manager.apply(.install)
        }
        #expect(!FileManager.default.fileExists(atPath: realDirectory.appending(path: "agent/extensions/cmux-sidebar-agent-status.ts").path))
    }
}
