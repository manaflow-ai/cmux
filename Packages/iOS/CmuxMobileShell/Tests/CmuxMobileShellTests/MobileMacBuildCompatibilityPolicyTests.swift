import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacBuildCompatibilityPolicyTests {
    @Test func developmentAllowsSiblingTagsWithoutBuildMetadata() {
        let policy = MobileMacBuildCompatibilityPolicy.development

        #expect(policy.allows(instanceTag: "icap"))
        #expect(policy.allows(instanceTag: " ICAP "))
        #expect(policy.allows(instanceTag: "tsmig"))
        #expect(!policy.allows(instanceTag: "default"))
        #expect(!policy.allows(instanceTag: "nightly"))
        #expect(!policy.allows(instanceTag: "rc"))
        #expect(!policy.allows(instanceTag: "staging"))
        #expect(!policy.allows(instanceTag: nil))
        #expect(policy.allows(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.debug.sibling"
        ))
        #expect(!policy.allows(
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.staging.sibling"
        ))
    }

    @Test func currentDevelopmentPolicyNeedsNoBuildMetadata() {
        let policy = MobileMacBuildCompatibilityPolicy.current()

        #expect(policy.allows(instanceTag: "phand1"))
        #expect(policy.allows(instanceTag: "phand2"))
        #expect(policy.allows(instanceTag: "phand3"))
        #expect(policy.allows(instanceTag: "unrelated"))
        #expect(!policy.allows(instanceTag: "default"))
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
        let development = MobileMacBuildCompatibilityPolicy.development

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
            instanceTag: "sibling",
            clientNamespace: "mac:com.cmuxterm.app.staging.sibling",
            macAppVersion: nil,
            usesLocallyAuthorizedTailscaleRoute: false
        ))
    }

    @Test func scopedDevelopmentStorePreservesSiblingRows() async throws {
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
        let scoped = MobileMacBuildCompatibilityPolicy.development.scoping(raw)

        #expect(Set(try await scoped.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).compactMap(\.instanceTag)) == ["icap", "tsmig"])
        #expect(try await scoped.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        )?.instanceTag == "tsmig")

        try await scoped.upsert(
            macDeviceID: "other-mac",
            displayName: "Other",
            routes: [route],
            instanceTag: "tsmig",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        )
        #expect(try await raw.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).contains { $0.macDeviceID == "other-mac" && $0.instanceTag == "tsmig" })
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
        let scoped = MobileMacBuildCompatibilityPolicy.development.scoping(raw)

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
        let scoped = MobileMacBuildCompatibilityPolicy.development.scoping(raw)

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
    @Test func registryProjectionKeepsEveryDevelopmentInstance() {
        let store = MobileShellComposite(
            buildCompatibilityPolicy: .development
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

        let projected = store.compatibleRegistryDevices([device])

        #expect(projected.count == 1)
        #expect(projected[0].instances.map(\.tag) == ["icap", "tsmig"])
        #expect(projected[0].lastSeenAt == Date(timeIntervalSince1970: 20))
    }

    @MainActor
    @Test func presenceProjectionKeepsEveryDevelopmentInstance() {
        let store = MobileShellComposite(
            buildCompatibilityPolicy: .development
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
    }
}
