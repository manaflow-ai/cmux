import CmuxSettings
import Foundation
import Testing

/// Behavior tests for ``SocketControlModePolicy``: which forced values an
/// administrator may set, how malformed and permissive values fail closed,
/// and the precedence between the dedicated policy key and a directly forced
/// user-level key.
///
/// Forced values cannot be produced without installing a real configuration
/// profile, so these tests drive ``ManagedDevicePolicy``'s injected probe: a
/// key counts as forced when the suite stores it under a `forced.`-prefixed
/// mirror key.
struct SocketControlModePolicyTests {
    private static let forcedMirrorPrefix = "forced."

    private static let probe: ManagedDevicePolicy.ForcedObjectProbe = { defaults, key in
        defaults.object(forKey: forcedMirrorPrefix + key)
    }

    private func makeSuite(_ label: String) throws -> (UserDefaults, () -> Void) {
        let suiteName = "SocketControlModePolicyTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makePolicy(defaults: UserDefaults) -> SocketControlModePolicy {
        SocketControlModePolicy(
            defaults: defaults,
            managedDevicePolicy: ManagedDevicePolicy(
                defaults: defaults,
                releaseDomainDefaults: nil,
                forcedObject: Self.probe
            )
        )
    }

    @Test func anUnmanagedMacReportsNoManagedMode() throws {
        let (defaults, cleanup) = try makeSuite("unmanaged")
        defer { cleanup() }

        // A plain user-level write is the user's own setting, not a policy.
        defaults.set(SocketControlMode.allowAll.rawValue, forKey: SocketControlSettings.appStorageKey)
        let policy = makePolicy(defaults: defaults)

        #expect(!policy.isManaged)
        #expect(policy.mode == nil)
    }

    @Test(arguments: [
        ("off", SocketControlMode.off),
        ("cmuxonly", SocketControlMode.cmuxOnly),
        ("cmuxOnly", SocketControlMode.cmuxOnly),
        ("  CMUX-ONLY  ", SocketControlMode.cmuxOnly),
        ("cmux_only", SocketControlMode.cmuxOnly),
        ("OFF", SocketControlMode.off),
    ])
    func administratorsMayForceTheRestrictiveModes(
        forcedValue: String,
        expected: SocketControlMode
    ) throws {
        let (defaults, cleanup) = try makeSuite("restrictive")
        defer { cleanup() }

        defaults.set(SocketControlMode.allowAll.rawValue, forKey: SocketControlSettings.appStorageKey)
        defaults.set(
            forcedValue,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.socketControlMode.rawValue
        )
        let policy = makePolicy(defaults: defaults)

        #expect(policy.isManaged)
        #expect(policy.mode == expected)
    }

    @Test(arguments: [
        "allowall",
        "openAccess",
        "automation",
        "password",
        "notifications",
        "full",
        "",
        "   ",
        "not-a-mode",
    ])
    func aForcedValueThatWouldOpenOrWeakenTheSocketFailsClosed(forcedValue: String) throws {
        let (defaults, cleanup) = try makeSuite("failClosed")
        defer { cleanup() }

        defaults.set(
            forcedValue,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.socketControlMode.rawValue
        )
        let policy = makePolicy(defaults: defaults)

        // A profile is still a profile: the key is managed, so every writer
        // locks. Only the resolved value falls back.
        #expect(policy.isManaged)
        #expect(policy.mode == .cmuxOnly)
    }

    @Test func aForcedNonStringValueIsManagedAndFailsClosed() throws {
        let (defaults, cleanup) = try makeSuite("wrongType")
        defer { cleanup() }

        defaults.set(
            true,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.socketControlMode.rawValue
        )
        let policy = makePolicy(defaults: defaults)

        #expect(policy.isManaged)
        #expect(policy.mode == .cmuxOnly)
    }

    @Test func forcingTheUserLevelKeyDirectlyAlsoManagesTheMode() throws {
        let (defaults, cleanup) = try makeSuite("userKeyForced")
        defer { cleanup() }

        // An administrator who forces `socketControlMode` instead of the
        // dedicated policy key gets the same lock.
        defaults.set(
            SocketControlMode.off.rawValue,
            forKey: Self.forcedMirrorPrefix + SocketControlSettings.appStorageKey
        )
        let policy = makePolicy(defaults: defaults)

        #expect(policy.isManaged)
        #expect(policy.mode == .off)
    }

    @Test func aForcedUserLevelKeyCannotOpenTheSocket() throws {
        let (defaults, cleanup) = try makeSuite("userKeyPermissive")
        defer { cleanup() }

        defaults.set(
            SocketControlMode.allowAll.rawValue,
            forKey: Self.forcedMirrorPrefix + SocketControlSettings.appStorageKey
        )
        let policy = makePolicy(defaults: defaults)

        #expect(policy.isManaged)
        #expect(policy.mode == .cmuxOnly)
    }

    @Test func theDedicatedKeyWinsOverAForcedUserLevelKey() throws {
        let (defaults, cleanup) = try makeSuite("precedence")
        defer { cleanup() }

        defaults.set(
            SocketControlMode.cmuxOnly.rawValue,
            forKey: Self.forcedMirrorPrefix + SocketControlSettings.appStorageKey
        )
        defaults.set(
            SocketControlMode.off.rawValue,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.socketControlMode.rawValue
        )
        let policy = makePolicy(defaults: defaults)

        #expect(policy.mode == .off)
    }

    @Test func aChannelBuildHonorsAProfileTargetingTheReleaseDomain() throws {
        let (appDefaults, cleanupApp) = try makeSuite("channelApp")
        defer { cleanupApp() }
        let (releaseDefaults, cleanupRelease) = try makeSuite("channelRelease")
        defer { cleanupRelease() }

        releaseDefaults.set(
            SocketControlMode.off.rawValue,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.socketControlMode.rawValue
        )
        let policy = SocketControlModePolicy(
            defaults: appDefaults,
            managedDevicePolicy: ManagedDevicePolicy(
                defaults: appDefaults,
                releaseDomainDefaults: releaseDefaults,
                forcedObject: Self.probe
            )
        )

        #expect(policy.isManaged)
        #expect(policy.mode == .off)
    }

    @Test func theExplicitInitializerDescribesAnUnmanagedMac() {
        let policy = SocketControlModePolicy(forcedRawValue: nil)

        #expect(!policy.isManaged)
        #expect(policy.mode == nil)
    }

    @Test func theExplicitInitializerDescribesAManagedMac() {
        let policy = SocketControlModePolicy(forcedRawValue: "off")

        #expect(policy.isManaged)
        #expect(policy.mode == .off)
    }
}
