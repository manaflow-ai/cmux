import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite(.serialized)
struct CmuxPluginSystemTests {
    @Test
    func pluginManifestUsesExplicitScopesAndRoundTripsLanguageNeutralJSON() throws {
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.plugin",
            displayName: "Example Plugin",
            pluginScopes: [.eventHooks, .paletteActions],
            eventSubscriptions: [.workspaceCreated, .notificationPosted],
            actions: [CmuxExtensionAction(
                id: "open-dashboard",
                title: "Open Dashboard",
                keywords: ["dashboard"],
                defaultShortcut: "cmd+shift+d"
            )],
            entrypoint: "bin/plugin"
        )

        try validatePluginManifest(manifest)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CmuxExtensionManifest.self, from: data)

        #expect(decoded == manifest)
        #expect(decoded.kind == .plugin)
        #expect(decoded.requestedPluginScopes == [.eventHooks, .paletteActions])
        #expect(CmuxPluginRegistry.namespacedActionID(
            pluginID: manifest.id,
            actionID: "open-dashboard"
        ) == "plugin.dev.example.plugin.open-dashboard")
    }

    @Test
    func snakeCaseManifestDecodingKeepsSidebarCompatibility() throws {
        let payload = Data("""
        {
          "id": "dev.example.plugin",
          "display_name": "Example Plugin",
          "kind": "plugin",
          "minimum_api_version": { "major": 3, "minor": 0 },
          "plugin_scopes": ["eventHooks"],
          "eventScopes": ["workspace.created"],
          "entrypoint": "bin/plugin"
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(CmuxExtensionManifest.self, from: payload)

        #expect(manifest.kind == .plugin)
        #expect(manifest.minimumAPIVersion == .pluginV3)
        #expect(manifest.eventSubscriptions == [.workspaceCreated])
        try validatePluginManifest(manifest)
    }

    @Test
    func manifestDecodingAcceptsSnakeCaseCapabilityValuesAndLifecycleAliases() throws {
        let payload = Data("""
        {
          "id": "dev.example.aliases",
          "display_name": "Aliases",
          "kind": "plugin",
          "plugin_scopes": ["event_hooks", "palette_actions"],
          "event_subscriptions": ["agent.session.state-changed", "notification.posted"],
          "actions": [{ "id": "run", "title": "Run" }],
          "entrypoint": "bin/plugin"
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(CmuxExtensionManifest.self, from: payload)

        #expect(manifest.pluginScopes == [.eventHooks, .paletteActions])
        #expect(manifest.eventSubscriptions == [.agentSessionStateChanged, .notificationPosted])
        try validatePluginManifest(manifest)
    }

    @Test(arguments: [
        "../escape",
        "dev/example",
        "dev example",
        "",
    ])
    func pluginManifestRejectsUnsafeIdentifiers(_ id: String) {
        let manifest = CmuxExtensionManifest.plugin(
            id: id,
            displayName: "Plugin",
            entrypoint: "bin/plugin"
        )

        do {
            try validatePluginManifest(manifest)
            Issue.record("Expected unsafe identifier to be rejected: \(id)")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == (id.isEmpty ? .emptyIdentifier : .invalidIdentifier(id)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func pluginManifestRequiresExplicitCapabilityFamilies() {
        let eventManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.events",
            displayName: "Events",
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        let actionManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.actions",
            displayName: "Actions",
            actions: [CmuxExtensionAction(id: "run", title: "Run")],
            entrypoint: "bin/plugin"
        )

        do {
            try validatePluginManifest(eventManifest)
            Issue.record("Expected missing eventHooks scope to fail")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .invalidDeclaration(
                kind: "scope",
                identifier: eventManifest.id,
                reason: "eventSubscriptions require the eventHooks plugin scope"
            ))
        } catch {
            Issue.record("Unexpected event scope error: \(error)")
        }

        do {
            try validatePluginManifest(actionManifest)
            Issue.record("Expected missing paletteActions scope to fail")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .invalidDeclaration(
                kind: "scope",
                identifier: actionManifest.id,
                reason: "actions require the paletteActions plugin scope"
            ))
        } catch {
            Issue.record("Unexpected action scope error: \(error)")
        }
    }

    @Test
    func pluginManifestRejectsDuplicateAndUnsupportedDeclarations() {
        let duplicateEvents = CmuxExtensionManifest.plugin(
            id: "dev.example.duplicates",
            displayName: "Duplicates",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated, .workspaceCreated],
            entrypoint: "bin/plugin"
        )
        let unsupportedSurface = CmuxExtensionManifest.plugin(
            id: "dev.example.surface",
            displayName: "Surface",
            pluginScopes: [.paneContent],
            entrypoint: "bin/plugin"
        )

        do {
            try validatePluginManifest(duplicateEvents)
            Issue.record("Expected duplicate event declaration to fail")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .duplicateDeclaration(kind: "event", identifier: "workspace.created"))
        } catch {
            Issue.record("Unexpected duplicate error: \(error)")
        }

        do {
            try validatePluginManifest(unsupportedSurface)
            Issue.record("Expected paneContent to fail in the core slice")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .unsupportedPluginScope(.paneContent))
        } catch {
            Issue.record("Unexpected scope error: \(error)")
        }
    }

    @Test
    func pluginManifestRejectsBareOrMalformedDefaultShortcuts() {
        let bare = CmuxExtensionManifest.plugin(
            id: "dev.example.bare",
            displayName: "Bare",
            pluginScopes: [.paletteActions],
            actions: [CmuxExtensionAction(id: "run", title: "Run", defaultShortcut: "r")],
            entrypoint: "bin/plugin"
        )
        let malformed = CmuxExtensionManifest.plugin(
            id: "dev.example.malformed",
            displayName: "Malformed",
            pluginScopes: [.paletteActions],
            actions: [CmuxExtensionAction(id: "run", title: "Run", defaultShortcut: "cmd++r")],
            entrypoint: "bin/plugin"
        )
        let modifierOnly = CmuxExtensionManifest.plugin(
            id: "dev.example.modifier-only",
            displayName: "Modifier Only",
            pluginScopes: [.paletteActions],
            actions: [CmuxExtensionAction(id: "run", title: "Run", defaultShortcut: "cmd+shift")],
            entrypoint: "bin/plugin"
        )

        for manifest in [bare, malformed, modifierOnly] {
            do {
                try validatePluginManifest(manifest)
                Issue.record("Expected shortcut declaration to fail: \(manifest.id)")
            } catch let error as CmuxExtensionValidationError {
                #expect(error == .invalidDeclaration(
                    kind: "action",
                    identifier: "run",
                    reason: "defaultShortcut must contain one or two valid strokes; the first stroke must be modifier-qualified"
                ))
            } catch {
                Issue.record("Unexpected shortcut validation error: \(error)")
            }
        }
    }

    @Test
    func processManifestRejectsSidebarScopesAndInvalidAPIVersionComponents() {
        let sidebarScopeManifest = CmuxExtensionManifest(
            id: "dev.example.mixed",
            displayName: "Mixed",
            readScopes: [.workspaceMetadata],
            minimumAPIVersion: .pluginV3,
            kind: .plugin,
            entrypoint: "bin/plugin"
        )
        do {
            try validatePluginManifest(sidebarScopeManifest)
            Issue.record("Process plugins must not silently claim sidebar scopes")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .invalidDeclaration(
                kind: "manifest",
                identifier: sidebarScopeManifest.id,
                reason: "process-backed plugins cannot declare sidebar-only read or action scopes"
            ))
        } catch {
            Issue.record("Unexpected mixed-manifest error: \(error)")
        }

        for version in [
            CmuxExtensionAPIVersion(major: 3, minor: -1),
            CmuxExtensionAPIVersion(major: -1, minor: 0),
        ] {
            let negativeVersionManifest = CmuxExtensionManifest(
                id: "dev.example.version",
                displayName: "Version",
                minimumAPIVersion: version,
                kind: .plugin,
                entrypoint: "bin/plugin"
            )
            do {
                try validatePluginManifest(negativeVersionManifest)
                Issue.record("Negative API components must fail closed")
            } catch let error as CmuxExtensionValidationError {
                #expect(error == .invalidDeclaration(
                    kind: "api",
                    identifier: negativeVersionManifest.id,
                    reason: "minimumAPIVersion components must be non-negative"
                ))
            } catch {
                Issue.record("Unexpected API-version error: \(error)")
            }
        }
    }

    @Test(arguments: [
        CmuxExtensionAPIVersion(major: 3, minor: 1),
        CmuxExtensionAPIVersion(major: 4, minor: 0),
        CmuxExtensionAPIVersion.sidebarV2,
    ])
    func pluginManifestRejectsUnsupportedAPIVersions(_ requestedVersion: CmuxExtensionAPIVersion) {
        let manifest = CmuxExtensionManifest(
            id: "dev.example.unsupported-version",
            displayName: "Unsupported Version",
            minimumAPIVersion: requestedVersion,
            kind: .plugin,
            entrypoint: "bin/plugin"
        )

        do {
            try validatePluginManifest(manifest)
            Issue.record("Unsupported plugin API version should fail closed: \(requestedVersion)")
        } catch let error as CmuxExtensionValidationError {
            #expect(error == .unsupportedPluginAPIVersion(
                requested: requestedVersion,
                supported: .pluginV3
            ))
        } catch {
            Issue.record("Unexpected API-version error: \(error)")
        }
    }

    @Test
    func directoryLoaderReportsFailuresAndAcceptsOnlyContainedExecutables() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let validManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.valid",
            displayName: "Valid",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(validManifest, to: root)

        let missing = root.appendingPathComponent("dev.example.missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)

        let mismatched = root.appendingPathComponent("dev.example.directory", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatched, withIntermediateDirectories: true)
        let mismatchManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.manifest",
            displayName: "Mismatch",
            entrypoint: "bin/plugin"
        )
        try JSONEncoder().encode(mismatchManifest).write(
            to: mismatched.appendingPathComponent("manifest.json")
        )

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()

        #expect(report.plugins.map { $0.manifest.id } == ["dev.example.valid"])
        #expect(report.failures.count == 2)
        #expect(report.failures.contains { $0.code == .missingManifest })
        #expect(report.failures.contains { $0.code == .directoryIdentifierMismatch })
        #expect(report.plugins.first?.entrypointURL?.path.hasPrefix(
            root.appendingPathComponent("dev.example.valid").path + "/"
        ) == true)
    }

    @Test
    func directoryLoaderSurfacesUnreadableRootAndRejectsExecutableDirectories() async throws {
        let parent = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nonDirectoryRoot = parent.appendingPathComponent("plugins", isDirectory: false)
        try Data("not a directory".utf8).write(to: nonDirectoryRoot)

        let rootFailure = await CmuxPluginDirectoryLoader(directoryURL: nonDirectoryRoot).load()
        #expect(rootFailure.plugins.isEmpty)
        #expect(rootFailure.failures.map(\.code) == [.unreadableDirectory])

        let root = parent.appendingPathComponent("valid-root", isDirectory: true)
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.directory-entrypoint",
            displayName: "Directory Entrypoint",
            entrypoint: "bin"
        )
        let pluginDirectory = root.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: pluginDirectory.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(
            to: pluginDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        )

        let entrypointFailure = await CmuxPluginDirectoryLoader(directoryURL: root).load()
        #expect(entrypointFailure.plugins.isEmpty)
        #expect(entrypointFailure.failures.map(\.code) == [.missingEntrypoint])
    }

    @Test
    func directoryLoaderRejectsPluginDirectoriesThatResolveOutsideRoot() async throws {
        let root = try Self.makeTemporaryDirectory()
        let outside = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.escape",
            displayName: "Escape",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: outside)
        let link = root.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent(manifest.id))

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()

        #expect(report.plugins.isEmpty)
        #expect(report.failures.contains { $0.code == .invalidManifest })
    }

    @Test
    func directoryLoaderUsesManifestBytesForSHA256Fingerprint() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.fingerprint",
            displayName: "Fingerprint",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let loader = CmuxPluginDirectoryLoader(directoryURL: root)

        let first = try #require((await loader.load()).plugins.first)
        #expect(first.manifestFingerprint.count == 64)
        #expect(first.manifestFingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        var changedManifest = manifest
        changedManifest.displayName = "Changed Fingerprint"
        let manifestURL = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        try JSONEncoder().encode(changedManifest).write(to: manifestURL, options: .atomic)

        let changed = try #require((await loader.load()).plugins.first)
        #expect(changed.manifestFingerprint.count == 64)
        #expect(changed.manifestFingerprint != first.manifestFingerprint)
    }

    @Test
    func permissionStoreSeparatesApprovalFromEnablementAndInvalidatesFingerprints() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.permissions",
            displayName: "Permissions",
            pluginScopes: [.eventHooks, .paletteActions],
            eventSubscriptions: [.workspaceCreated],
            actions: [CmuxExtensionAction(id: "run", title: "Run")],
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let plugin = try #require((await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first)
        let store = CmuxPluginPermissionStore(storageURL: nil)

        #expect(await store.permissions(for: plugin) == .none)
        do {
            try await store.setEnabled(true, for: plugin)
            Issue.record("Enabling an unapproved plugin should fail")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .notApproved)
        }

        try await store.approveAll(for: plugin)
        let approved = await store.permissions(for: plugin)
        #expect(approved.enabled)
        #expect(approved.events == [.workspaceCreated])
        #expect(approved.actions == ["run"])

        try await store.setEnabled(false, for: plugin)
        #expect(await store.permissions(for: plugin) == .none)

        let changed = CmuxLoadedPlugin(
            manifest: manifest,
            directoryURL: plugin.directoryURL,
            entrypointURL: plugin.entrypointURL,
            manifestFingerprint: "changed"
        )
        #expect(await store.permissions(for: changed) == .none)
        #expect((await store.grant(for: changed)).approved == false)
    }

    @Test
    func permissionStoreDoesNotPublishGrantWhenPersistenceFails() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedParent = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("blocked".utf8).write(to: blockedParent)
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.persistence",
            displayName: "Persistence",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        let plugin = CmuxLoadedPlugin(
            manifest: manifest,
            directoryURL: root.appendingPathComponent(manifest.id, isDirectory: true),
            entrypointURL: root.appendingPathComponent("plugin", isDirectory: false),
            manifestFingerprint: "fingerprint"
        )
        let store = CmuxPluginPermissionStore(
            storageURL: blockedParent.appendingPathComponent("plugin-grants.json")
        )

        do {
            try await store.approveAll(for: plugin)
            Issue.record("A failed grant write must report an error")
        } catch {
            #expect((await store.grant(for: plugin)).approved == false)
            #expect(await store.permissions(for: plugin) == .none)
        }
    }

}
