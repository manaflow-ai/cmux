import Foundation
import Testing

@testable import CmuxSettings

/// Channel/override/startup rules for the control socket path.
///
/// These moved out of the app-host `cmuxTests` bundle: every assertion here is
/// on `CmuxSettings` value types only, so the app host bought nothing.
/// ``SocketControlSettingsTests`` covers mode resolution and the XCTest socket
/// fallback; this suite covers bundle-channel defaults, override refusal, and
/// the pre-listener startup probe.
@Suite struct SocketControlSettingsChannelTests {
    // MARK: - Mode and permissions

    @Test func migrateModeAcceptsEveryCanonicalSpelling() {
        #expect(SocketControlSettings.migrateMode("off") == .off)
        #expect(SocketControlSettings.migrateMode("cmuxOnly") == .cmuxOnly)
        #expect(SocketControlSettings.migrateMode("automation") == .automation)
        #expect(SocketControlSettings.migrateMode("password") == .password)
        #expect(SocketControlSettings.migrateMode("allow-all") == .allowAll)
    }

    @Test func socketFilePermissionsAreRestrictiveExceptForAllowAll() {
        #expect(SocketControlMode.off.socketFilePermissions == 0o600)
        #expect(SocketControlMode.cmuxOnly.socketFilePermissions == 0o600)
        #expect(SocketControlMode.automation.socketFilePermissions == 0o600)
        #expect(SocketControlMode.password.socketFilePermissions == 0o600)
        #expect(SocketControlMode.allowAll.socketFilePermissions == 0o666)
    }

    @Test func invalidEnvSocketModeDoesNotOverrideUserMode() {
        #expect(
            SocketControlSettings.envOverrideMode(
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            ) == nil
        )
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            ) == .password
        )
    }

    // MARK: - Ambient override handling per channel

    @Test func stableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "stray-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == SocketControlSettings.stableDefaultSocketPath)
    }

    @Test func taggedDebugLaunchUsesTagDefaultWhenNoOverrideIsProvided() {
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_TAG": "my-tag"],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        #expect(path == "/tmp/cmux-debug-my-tag.sock")
    }

    @Test func taggedDebugLaunchStillHonorsSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "my-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        #expect(path == "/tmp/cmux-debug-forced.sock")
    }

    @Test func nightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock"],
            bundleIdentifier: "com.cmuxterm.app.nightly",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == "/tmp/cmux-nightly.sock")
    }

    @Test func taggedDebugBundleKeepsMatchingSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-debug-my-tag.sock"],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-my-tag.sock")
    }

    @Test func taggedDebugBundleIgnoresSocketOverrideInheritedFromDifferentCmuxBundle() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.issue.4355.cmux.themes.set.state.dependent",
            isDebugBuild: true
        )

        #expect(path == "/tmp/cmux-debug-issue-4355-cmux-themes-set-state-dependent.sock")
    }

    @Test func taggedDebugBundleIgnoresMismatchedInheritedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-fix-grok-notifications.sock")
    }

    @Test func taggedDebugBundleCanOptInToMismatchedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-nightly.sock")
    }

    @Test func stagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/cmux-staging-my-tag.sock"],
            bundleIdentifier: "com.cmuxterm.app.staging.my-tag",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-staging-my-tag.sock")
    }

    @Test func stableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == "/tmp/cmux-debug-forced.sock")
    }

    // MARK: - Stable-socket hijack refusal

    @Test func taggedDebugBundleRefusesStableSocketOverrideEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-sockguard.sock")
    }

    @Test func taggedDebugBundleRefusesUserScopedStableSocketOverrideEvenWithOptInFlag() {
        let aliases = [
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501),
            "/private/tmp/cmux-501.sock",
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            #expect(path == "/tmp/cmux-debug-sockguard.sock", "alias: \(alias)")
        }
    }

    @Test func taggedDebugBundleRefusesCanonicalLegacyStableSocketAliasEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/private/tmp/cmux.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-sockguard.sock")
    }

    @Test func socketPathMatchingTreatsPrivateTmpLegacyStableAliasAsSamePath() {
        #expect(
            SocketControlSettings.pathsMatch(
                SocketControlSettings.legacyStableDefaultSocketPath,
                "/private/tmp/cmux.sock"
            )
        )
    }

    @Test func taggedDebugBundleRefusesCaseVariantStableSocketAliasesEvenWithOptInFlag() {
        let aliases = [
            "/tmp/CMUX.sock",
            "/private/tmp/CMUX.sock",
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            #expect(path == "/tmp/cmux-debug-sockguard.sock", "alias: \(alias)")
        }
    }

    @Test func taggedDebugBundleRefusesLeafSymlinkToStableSocketEvenWithOptInFlag() throws {
        let alias = "/tmp/cmux-stable-alias-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        defer { try? FileManager.default.removeItem(atPath: alias) }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": alias,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-sockguard.sock")
    }

    @Test func taggedDebugBundleRefusesExcessiveSymlinkChainEvenWithOptInFlag() throws {
        let root = "/tmp/cmux-stable-chain-\(UUID().uuidString)"
        let aliases = (0...64).map { "\(root)-\($0).sock" }
        for alias in aliases {
            try? FileManager.default.removeItem(atPath: alias)
        }
        defer {
            for alias in aliases {
                try? FileManager.default.removeItem(atPath: alias)
            }
        }

        try FileManager.default.createSymbolicLink(
            atPath: aliases[64],
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        for index in stride(from: 63, through: 0, by: -1) {
            try FileManager.default.createSymbolicLink(
                atPath: aliases[index],
                withDestinationPath: aliases[index + 1]
            )
        }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": aliases[0],
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/cmux-debug-sockguard.sock")
    }

    // MARK: - Default path per channel

    @Test func defaultSocketPathByChannel() {
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == SocketControlSettings.stableDefaultSocketPath
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/cmux-nightly.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.nightly.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/cmux-nightly-tag.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/cmux-debug-tag.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/cmux-staging-tag.sock"
        )
    }

    @Test func stableReleaseFallsBackToUserScopedSocketWhenStablePathOwnedByDifferentUser() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 0) }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func stableReleaseFallsBackToUserScopedSocketWhenStablePathIsBlockedByNonSocketEntry() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .other(ownerUserID: 501) }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    // MARK: - Pre-listener startup path

    @Test func initialStableLaunchFallsBackToUserScopedSocketWhenSameUserStablePathIsLive() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in false }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchTreatsPrivateTmpLegacyStableAliasAsStablePath() {
        var probedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: "/private/tmp/cmux.sock",
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                probedPath = socketPath
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { _ in false }
        )

        #expect(probedPath == "/private/tmp/cmux.sock")
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchUsesTransportReclaimabilityForSameUserSocket() {
        var didProbe = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in
                didProbe = true
                return false
            }
        )

        #expect(didProbe)
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchKeepsStablePathWhenTransportReclaimsSameUserSocket() {
        var reclaimedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                reclaimedPath = socketPath
                return true
            }
        )

        #expect(reclaimedPath == SocketControlSettings.stableDefaultSocketPath)
        #expect(path == SocketControlSettings.stableDefaultSocketPath)
    }

    @Test func initialStableLaunchKeepsUserScopedPreferredPathWithoutProbing() {
        let userScopedPath = SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        var didInspect = false
        var didReclaim = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: userScopedPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                didInspect = true
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { _ in
                didReclaim = true
                return false
            }
        )

        #expect(!didInspect, "User-scoped startup path must not be re-inspected")
        #expect(!didReclaim, "User-scoped startup path must not be reclaimed")
        #expect(path == userScopedPath)
    }

    @Test func initialStableLaunchFallsBackToUserScopedSocketWhenMissingStablePathCannotBeReserved() {
        var reclaimedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                reclaimedPath = socketPath
                return false
            }
        )

        #expect(reclaimedPath == SocketControlSettings.stableDefaultSocketPath)
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialSocketPathDoesNotProbeForTaggedDebugBuild() {
        let debugPath = "/tmp/cmux-debug-tag.sock"
        var didInspect = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: debugPath,
            bundleIdentifier: "com.cmuxterm.app.debug.tag",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                didInspect = true
                return .socket(ownerUserID: 501)
            }
        )

        #expect(!didInspect, "Tagged debug builds must not inspect the stable socket")
        #expect(path == debugPath)
    }

    // MARK: - Untagged-debug launch gate

    @Test func untaggedDebugBundleAllowedWithLaunchTag() {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_TAG": "tests-v1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    @Test func releaseBuildOfADebugBundleIgnoresLaunchTagGate() {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: false
            )
        )
    }

    @Test(arguments: [
        ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"],
        ["XCInjectBundle": "/tmp/fake.xctest"],
        ["DYLD_INSERT_LIBRARIES": "/usr/lib/libXCTestBundleInject.dylib"],
        // XCUITest launches the app as a separate process without XCTest env
        // vars; the app receives CMUX_UI_TEST_* via XCUIApplication.launchEnvironment.
        ["CMUX_UI_TEST_MODE": "1"],
    ])
    func testHarnessLaunchesIgnoreLaunchTagGate(environment: [String: String]) {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: environment,
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }
}
