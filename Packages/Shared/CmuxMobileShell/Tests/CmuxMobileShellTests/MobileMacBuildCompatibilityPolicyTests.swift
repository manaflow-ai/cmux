import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacBuildCompatibilityPolicyTests {
    @Test func developmentDefaultsToExactTagIsolation() {
        let policy = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap"
        )

        #expect(policy.allows(instanceTag: "icap"))
        #expect(policy.allows(instanceTag: " ICAP "))
        #expect(!policy.allows(instanceTag: "tsmig"))
        #expect(!policy.allows(instanceTag: "default"))
        #expect(!policy.allows(instanceTag: "nightly"))
        #expect(!policy.allows(instanceTag: "rc"))
        #expect(!policy.allows(instanceTag: "staging"))
        #expect(!policy.allows(instanceTag: nil))
    }

    @Test func developmentAllowlistGrantsSiblingTags() {
        let policy = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap",
            additionalInstanceTags: MobileMacTagAllowlist(tags: ["tsmig", " Phand2 "])
        )

        #expect(policy.allows(instanceTag: "tsmig"))
        #expect(policy.allows(instanceTag: "phand2"))
        #expect(policy.allows(instanceTag: " TSMIG "))
        #expect(!policy.allows(instanceTag: "unrelated"))
        // Release lanes are never grantable, even if advertised.
        let reserved = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap",
            additionalInstanceTags: MobileMacTagAllowlist(tags: ["default", "nightly", "rc", "staging"])
        )
        #expect(!reserved.allows(instanceTag: "default"))
        #expect(!reserved.allows(instanceTag: "nightly"))
        #expect(!reserved.allows(instanceTag: "rc"))
        #expect(!reserved.allows(instanceTag: "staging"))
    }

    @Test func developmentKeepsMacNamespaceGating() {
        let policy = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "sibling",
            additionalInstanceTags: MobileMacTagAllowlist(tags: ["granted"])
        )

        #expect(policy.allows(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.debug.sibling"
        ))
        #expect(policy.allows(
            instanceTag: "granted",
            clientNamespace: "mac:com.cmuxterm.app.debug.granted"
        ))
        #expect(!policy.allows(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.staging.sibling"
        ))
        #expect(!policy.allows(
            instanceTag: "granted",
            clientNamespace: "mac:com.cmuxterm.app"
        ))
    }

    @Test func runtimeAllowlistMutationIsVisibleToTheSamePolicyValue() {
        let allowlist = MobileMacTagAllowlist()
        let policy = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap",
            additionalInstanceTags: allowlist
        )

        #expect(!policy.allows(instanceTag: "tsmig"))
        allowlist.replace(with: ["tsmig"])
        #expect(policy.allows(instanceTag: "tsmig"))
        allowlist.replace(with: [])
        #expect(!policy.allows(instanceTag: "tsmig"))
    }

    @Test func allowlistPersistsAcrossInstances() throws {
        let suiteName = "mac-tag-allowlist-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MobileMacTagAllowlist.persisted(defaults: defaults)
        #expect(first.tags.isEmpty)
        #expect(first.replace(with: [" TSMIG ", "phand2", "default", ""]))
        #expect(first.tags == ["phand2", "tsmig"])
        // An equal advertisement after normalization is a no-op.
        #expect(!first.replace(with: ["tsmig", "PHAND2"]))

        let second = MobileMacTagAllowlist.persisted(defaults: defaults)
        #expect(second.tags == ["phand2", "tsmig"])
    }

    @Test func currentDevelopmentPolicyBindsToTheBuildScope() throws {
        let allowlist = MobileMacTagAllowlist(tags: ["granted"])
        let policy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: try #require(MobileIOSBuildScope("feature")),
            additionalInstanceTags: allowlist
        )

        #expect(policy.allows(instanceTag: "feature"))
        #expect(policy.allows(instanceTag: "granted"))
        #expect(!policy.allows(instanceTag: "unrelated"))
        #expect(!policy.allows(instanceTag: "default"))

        let untagged = MobileMacBuildCompatibilityPolicy.current(buildScope: nil)
        #expect(untagged.allows(instanceTag: "dev"))
        #expect(!untagged.allows(instanceTag: "unrelated"))
    }

    @Test func officialKeepsStableAndNightlyAsDistinctAllowedIdentities() {
        let policy = MobileMacBuildCompatibilityPolicy.official

        #expect(policy.allows(instanceTag: "default"))
        #expect(policy.allows(instanceTag: "nightly"))
        #expect(!policy.allows(instanceTag: "icap"))
        #expect(!policy.allows(instanceTag: "rc"))
        #expect(!policy.allows(instanceTag: "staging"))
        #expect(!policy.allows(instanceTag: nil))
    }

    @Test func officialAllowsOnlyAuthorizedLegacy06417WithoutAnInstanceTag() {
        let policy = MobileMacBuildCompatibilityPolicy.official

        #expect(policy.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: "0.64.17",
            usesLocallyAuthorizedTailscaleRoute: true
        ))
        #expect(!policy.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: "0.64.17",
            usesLocallyAuthorizedTailscaleRoute: false
        ))
        #expect(!policy.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: "0.64.18",
            usesLocallyAuthorizedTailscaleRoute: true
        ))
        #expect(!policy.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: true
        ))
        #expect(!policy.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: "0.64.17-beta",
            usesLocallyAuthorizedTailscaleRoute: true
        ))
    }

    @Test func legacyExceptionNeverWeakensTaggedOrDevelopmentIdentity() {
        let official = MobileMacBuildCompatibilityPolicy.official
        let development = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "mine",
            additionalInstanceTags: MobileMacTagAllowlist(tags: ["sibling"])
        )

        #expect(official.allowsAuthenticatedHost(
            instanceTag: "default",
            macAppVersion: "0.64.17",
            usesLocallyAuthorizedTailscaleRoute: false
        ))
        #expect(!official.allowsAuthenticatedHost(
            instanceTag: "other",
            macAppVersion: "0.64.17",
            usesLocallyAuthorizedTailscaleRoute: true
        ))
        #expect(!development.allowsAuthenticatedHost(
            instanceTag: nil,
            macAppVersion: "0.64.17",
            usesLocallyAuthorizedTailscaleRoute: true
        ))
        // Development direct pairing still requires the Mac bundle namespace.
        #expect(!development.allowsAuthenticatedHost(
            instanceTag: "sibling",
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: false
        ))
        #expect(development.allowsAuthenticatedHost(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.debug.sibling",
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: false
        ))
        #expect(!development.allowsAuthenticatedHost(
            instanceTag: "ungranted",
            clientNamespace: "mac:com.cmuxterm.app.debug.ungranted",
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: false
        ))
        #expect(!development.allowsAuthenticatedHost(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.staging.sibling",
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: false
        ))
    }

    @Test func scopedDevelopmentStoreHidesUngrantedSiblingsUntilGranted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "test",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 22)
        )
        for (tag, seen) in [("icap", 1.0), ("tsmig", 2.0)] {
            try await raw.upsert(
                macDeviceID: "shared-mac",
                displayName: tag,
                routes: [route],
                instanceTag: tag,
                markActive: tag == "tsmig",
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: seen)
            )
        }
        let allowlist = MobileMacTagAllowlist()
        let scoped = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "tsmig",
            additionalInstanceTags: allowlist
        ).scoping(raw)

        // Default: only the exact-tag Mac projects.
        #expect(Set(try await scoped.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).compactMap(\.instanceTag)) == ["tsmig"])
        #expect(try await scoped.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        )?.instanceTag == "tsmig")

        // A runtime grant makes the stored sibling row visible with no
        // re-pair; revocation hides it again.
        allowlist.replace(with: ["icap"])
        #expect(Set(try await scoped.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).compactMap(\.instanceTag)) == ["icap", "tsmig"])
        allowlist.replace(with: [])
        #expect(Set(try await scoped.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).compactMap(\.instanceTag)) == ["tsmig"])
    }

    @Test func scopedStoreKeepsUnclaimedLegacyRowsMigratable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let originalRoute = try CmxAttachRoute(
            id: "legacy",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 22)
        )
        let updatedRoute = try CmxAttachRoute(
            id: "legacy-updated",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.2", port: 22)
        )
        try await raw.upsert(
            macDeviceID: "legacy-mac",
            displayName: "Legacy",
            routes: [originalRoute],
            instanceTag: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let scoped = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap"
        ).scoping(raw)

        #expect(try await scoped.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).map(\.macDeviceID) == ["legacy-mac"])
        let updated = try await scoped.upsertRoutesIfAuthorized(
            macDeviceID: "legacy-mac",
            displayName: "Legacy",
            routes: [updatedRoute],
            condition: .unclaimed,
            markActive: nil,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(updated)
        #expect(try await raw.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).first?.routes == [updatedRoute])
    }

    @Test func scopedRemoveAllRemovesAllDevelopmentRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "test",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 22)
        )
        for (tag, seenAt) in [("icap", 1.0), ("tsmig", 2.0)] {
            try await raw.upsert(
                macDeviceID: "shared-mac",
                displayName: tag,
                routes: [route],
                instanceTag: tag,
                markActive: false,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: seenAt)
            )
        }
        let scoped = MobileMacBuildCompatibilityPolicy.development(
            expectedInstanceTag: "icap"
        ).scoping(raw)

        try await scoped.removeAll()

        #expect(try await raw.loadAll(
            stackUserID: nil, teamID: nil
        ).isEmpty)
    }

    @Test func officialStoreKeepsStableAndNightlyButRejectsDevelopment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "test",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 22)
        )
        for (tag, seen) in [("default", 1.0), ("nightly", 2.0), ("icap", 3.0)] {
            try await raw.upsert(
                macDeviceID: "shared-mac",
                displayName: tag,
                routes: [route],
                instanceTag: tag,
                markActive: false,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: seen)
            )
        }
        let official = MobileMacBuildCompatibilityPolicy.official.scoping(raw)

        #expect(Set(try await official.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).compactMap(\.instanceTag)) == ["default", "nightly"])
    }

    @MainActor
    @Test func registryProjectionKeepsOnlyExpectedAndGrantedInstances() {
        let allowlist = MobileMacTagAllowlist()
        let store = MobileShellComposite(
            buildCompatibilityPolicy: .development(
                expectedInstanceTag: "tsmig",
                additionalInstanceTags: allowlist
            )
        )
        let device = RegistryDevice(
            deviceId: "shared-mac",
            platform: "mac",
            displayName: "Mac",
            lastSeenAt: Date(timeIntervalSince1970: 20),
            instances: [
                RegistryAppInstance(
                    tag: "icap", routes: [], lastSeenAt: Date(timeIntervalSince1970: 10)
                ),
                RegistryAppInstance(
                    tag: "tsmig", routes: [], lastSeenAt: Date(timeIntervalSince1970: 20)
                ),
            ]
        )

        let isolated = store.compatibleRegistryDevices([device])
        #expect(isolated.count == 1)
        #expect(isolated[0].instances.map(\.tag) == ["tsmig"])

        allowlist.replace(with: ["icap"])
        let granted = store.compatibleRegistryDevices([device])
        #expect(granted.count == 1)
        #expect(granted[0].instances.map(\.tag) == ["icap", "tsmig"])
        #expect(granted[0].lastSeenAt == Date(timeIntervalSince1970: 20))
    }

    @MainActor
    @Test func presenceProjectionKeepsOnlyExpectedAndGrantedInstances() {
        let allowlist = MobileMacTagAllowlist(tags: ["icap"])
        let store = MobileShellComposite(
            buildCompatibilityPolicy: .development(
                expectedInstanceTag: "tsmig",
                additionalInstanceTags: allowlist
            )
        )
        let icap = PresenceInstance(
            deviceId: "shared-mac",
            tag: "icap",
            platform: "mac",
            online: false,
            lastSeenAt: 10
        )
        let tsmig = PresenceInstance(
            deviceId: "shared-mac",
            tag: "tsmig",
            platform: "mac",
            online: true,
            lastSeenAt: 20
        )
        let update = PresenceUpdate.snapshot(PresenceSnapshot(
            teamId: "team-a",
            now: 20,
            heartbeatIntervalMs: 5,
            offlineTimeoutMs: 15,
            devices: [PresenceDevice(
                deviceId: "shared-mac",
                platform: "mac",
                displayName: "Mac",
                online: true,
                lastSeenAt: 20,
                instances: [icap, tsmig]
            )]
        ))

        let projected = store.compatiblePresenceUpdate(update)
        guard case .snapshot(let snapshot) = projected else {
            Issue.record("expected a compatible presence snapshot")
            return
        }
        #expect(snapshot.devices.count == 1)
        #expect(snapshot.devices[0].instances.map(\.tag) == ["icap", "tsmig"])
        #expect(snapshot.devices[0].online)
        #expect(snapshot.devices[0].lastSeenAt == 20)
        #expect(store.compatiblePresenceUpdate(.online(tsmig)) == .online(tsmig))

        // Revoking the grant filters the sibling out of the same update.
        allowlist.replace(with: [])
        guard case .snapshot(let isolated)? = store.compatiblePresenceUpdate(update) else {
            Issue.record("expected a compatible presence snapshot")
            return
        }
        #expect(isolated.devices[0].instances.map(\.tag) == ["tsmig"])
        #expect(store.compatiblePresenceUpdate(.online(icap)) == nil)
    }
}
