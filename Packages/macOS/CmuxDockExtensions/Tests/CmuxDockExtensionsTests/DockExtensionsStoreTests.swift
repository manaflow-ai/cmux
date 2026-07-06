import Foundation
import Testing
@testable import CmuxDockExtensions

@MainActor
private final class FakeHost: DockExtensionsHost {
    var currentAppVersion = "0.99.0"
    var openedRequests: [DockExtensionPaneOpenRequest] = []
    var openResult = true
    var activationCount = 0

    func openExtensionPane(_ request: DockExtensionPaneOpenRequest) -> Bool {
        openedRequests.append(request)
        return openResult
    }

    func activateDockForExtensions() {
        activationCount += 1
    }
}

@MainActor
@Suite("DockExtensionsStore", .serialized)
struct DockExtensionsStoreTests {
    private struct Harness {
        let home: URL
        let directories: DockExtensionDirectories
        let store: DockExtensionsStore
        let host: FakeHost
    }

    private func makeHarness() throws -> Harness {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let directories = DockExtensionDirectories(homeDirectory: home)
        let store = DockExtensionsStore(
            directories: directories,
            repository: InstalledDockExtensionsRepository(fileURL: directories.lockFileURL),
            buildRunner: DockExtensionBuildRunner(loginShellPath: { "/bin/sh" })
        )
        let host = FakeHost()
        store.attachHost(host)
        return Harness(home: home, directories: directories, store: store, host: host)
    }

    private func writeManifest(
        _ manifest: String, to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(
            to: directory.appendingPathComponent(DockExtensionManifest.manifestFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private let helloManifest = """
    { "manifestVersion": 1, "id": "hello", "name": "Hello TUI", "version": "1.0",
      "icon": "sparkles",
      "build": [ { "command": ["/bin/sh", "-c", "echo built > built.marker"] } ],
      "panes": [
        { "id": "main", "title": "Hello", "command": ["./hello.sh", "with space"],
          "env": { "HELLO_MODE": "demo" } }
      ] }
    """

    @Test func linkProjectsAndOpensPane() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        let devDirectory = harness.home.appendingPathComponent("dev-ext", isDirectory: true)
        try writeManifest(helloManifest, to: devDirectory)

        try await harness.store.link(directoryPath: devDirectory.path)
        #expect(harness.store.installed.count == 1)
        let installed = try #require(harness.store.installedExtension(id: "hello"))
        #expect(installed.isLinked)
        #expect(installed.status == .ok)
        #expect(installed.displayName == "Hello TUI")
        #expect(installed.launchablePanes.map(\.id) == ["main"])
        #expect(harness.host.activationCount == 1)

        try harness.store.openPane(qualifiedId: "hello.main")
        let request = try #require(harness.host.openedRequests.first)
        #expect(request.controlId == "hello.main")
        #expect(request.title == "Hello TUI")
        #expect(request.iconSystemName == "sparkles")
        #expect(request.shellCommand == "./hello.sh 'with space'")
        #expect(request.workingDirectory == installed.rootDirectory.path)
        #expect(request.environment["HELLO_MODE"] == "demo")
        #expect(request.environment["CMUX_EXTENSION_ID"] == "hello")
        #expect(request.environment["CMUX_EXTENSION_PANE_ID"] == "main")
        #expect(request.environment["CMUX_EXTENSION_ROOT"] == installed.rootDirectory.path)
        #expect(request.environment["CMUX_EXTENSION_ENV"] == "1")
        let configDir = try #require(request.environment["CMUX_EXTENSION_CONFIG_DIR"])
        let stateDir = try #require(request.environment["CMUX_EXTENSION_STATE_DIR"])
        #expect(FileManager.default.fileExists(atPath: configDir))
        #expect(FileManager.default.fileExists(atPath: stateDir))
    }

    @Test func installRunsBuildMovesCheckoutAndRecordsPin() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        let staging = harness.directories.makeStagingDirectory()
        try writeManifest(helloManifest, to: staging)
        let manifest = try DockExtensionManifestLoader().load(fromDirectory: staging)
        let sha = String(repeating: "b", count: 40)
        let preview = DockExtensionInstallPreview(
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            resolvedSha: sha,
            ref: nil,
            manifest: manifest,
            stagingDirectory: staging,
            warnings: [],
            kind: .install
        )

        try await harness.store.install(preview)

        let checkout = harness.directories.checkoutDirectory(id: "hello")
        #expect(FileManager.default.fileExists(
            atPath: checkout.appendingPathComponent("built.marker").path
        ))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let installed = try #require(harness.store.installedExtension(id: "hello"))
        #expect(installed.status == .ok)
        #expect(installed.record.pinnedSha == sha)
        #expect(!installed.isLinked)
        #expect(harness.host.activationCount == 1)

        // A drifted on-disk manifest (changed command) demands re-consent.
        let drifted = helloManifest.replacingOccurrences(of: "./hello.sh", with: "./evil.sh")
        try writeManifest(drifted, to: checkout)
        await harness.store.reload()
        let reloaded = try #require(harness.store.installedExtension(id: "hello"))
        #expect(reloaded.status == .needsReconsent)
        #expect(reloaded.launchablePanes.isEmpty)
        #expect(throws: DockExtensionError.needsReconsent(id: "hello")) {
            try harness.store.openPane(qualifiedId: "hello.main")
        }
    }

    @Test func failingBuildAbortsAndCleansUp() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        let staging = harness.directories.makeStagingDirectory()
        let failing = helloManifest.replacingOccurrences(
            of: "echo built > built.marker",
            with: "exit 7"
        )
        try writeManifest(failing, to: staging)
        let manifest = try DockExtensionManifestLoader().load(fromDirectory: staging)
        let preview = DockExtensionInstallPreview(
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            resolvedSha: String(repeating: "c", count: 40),
            ref: nil,
            manifest: manifest,
            stagingDirectory: staging,
            warnings: [],
            kind: .install
        )
        await #expect(throws: DockExtensionError.self) {
            try await harness.store.install(preview)
        }
        await harness.store.reload()
        #expect(harness.store.installed.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: harness.directories.checkoutDirectory(id: "hello").path
        ))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func disableUninstallAndDuplicateGuards() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        let staging = harness.directories.makeStagingDirectory()
        try writeManifest(helloManifest, to: staging)
        let manifest = try DockExtensionManifestLoader().load(fromDirectory: staging)
        let preview = DockExtensionInstallPreview(
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            resolvedSha: String(repeating: "d", count: 40),
            ref: nil,
            manifest: manifest,
            stagingDirectory: staging,
            warnings: [],
            kind: .install
        )
        try await harness.store.install(preview)

        // Linking a same-id directory conflicts with the GitHub install.
        let devDirectory = harness.home.appendingPathComponent("dev-ext", isDirectory: true)
        try writeManifest(helloManifest, to: devDirectory)
        await #expect(throws: DockExtensionError.duplicateId("hello")) {
            try await harness.store.link(directoryPath: devDirectory.path)
        }

        try await harness.store.setEnabled(id: "hello", enabled: false)
        #expect(throws: DockExtensionError.extensionDisabled(id: "hello")) {
            try harness.store.openPane(qualifiedId: "hello.main")
        }

        try await harness.store.uninstall(id: "hello")
        #expect(harness.store.installed.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: harness.directories.checkoutDirectory(id: "hello").path
        ))
        #expect(throws: DockExtensionError.notInstalled(id: "hello")) {
            try harness.store.openPane(qualifiedId: "hello.main")
        }
    }

    @Test func minCmuxVersionGateUsesHostVersion() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.host.currentAppVersion = "0.10.0"
        let devDirectory = harness.home.appendingPathComponent("dev-ext", isDirectory: true)
        let demanding = helloManifest.replacingOccurrences(
            of: "\"version\": \"1.0\",",
            with: "\"version\": \"1.0\", \"minCmuxVersion\": \"0.50.0\","
        )
        try writeManifest(demanding, to: devDirectory)
        await #expect(throws: DockExtensionError.minCmuxVersionNotSatisfied(
            required: "0.50.0", current: "0.10.0"
        )) {
            try await harness.store.link(directoryPath: devDirectory.path)
        }
    }
}

@MainActor
@Suite("DockExtensionsStore hardening", .serialized)
struct DockExtensionsStoreHardeningTests {
    @Test func malformedLockfileIdNeverDeletesOutsideCheckouts() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let directories = DockExtensionDirectories(homeDirectory: home)
        let repository = InstalledDockExtensionsRepository(fileURL: directories.lockFileURL)
        // Victim directory that a traversal id would resolve to:
        // checkouts/../victim == extensions/victim.
        let victim = directories.stateRoot.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "keep".write(
            to: victim.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8
        )
        try await repository.upsert(DockExtensionInstallRecord(
            id: "../victim",
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            pinnedSha: String(repeating: "a", count: 40),
            installedAt: Date(),
            consentFingerprint: "fp"
        ))
        let store = DockExtensionsStore(directories: directories, repository: repository)
        await store.reload()
        // Projection refuses the traversal path (record shows unavailable, no
        // panes) and uninstall removes the record but never the victim dir.
        let installed = try #require(store.installedExtension(id: "../victim"))
        #expect(installed.launchablePanes.isEmpty)
        try await store.uninstall(id: "../victim")
        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("data.txt").path))
        #expect(store.installed.isEmpty)
    }

    @Test func oversizedManifestIsRejectedBeforeReading() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-oversize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let devDirectory = home.appendingPathComponent("dev-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: devDirectory, withIntermediateDirectories: true)
        let big = "{\"padding\": \"" + String(repeating: "x", count: DockExtensionManifest.maximumFileSize) + "\"}"
        try big.write(
            to: devDirectory.appendingPathComponent(DockExtensionManifest.manifestFileName),
            atomically: true, encoding: .utf8
        )
        #expect(throws: DockExtensionError.manifestTooLarge(limitBytes: DockExtensionManifest.maximumFileSize)) {
            try DockExtensionManifestLoader().load(fromDirectory: devDirectory)
        }
    }
}
