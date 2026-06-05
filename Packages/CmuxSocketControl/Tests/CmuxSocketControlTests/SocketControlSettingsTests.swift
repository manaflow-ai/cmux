import Testing

import CmuxSettings
@testable import CmuxSocketControl

@Suite struct SocketControlSettingsTests {
    @Test func migrateModeMapsLegacyAndUnknownValues() {
        #expect(SocketControlSettings.migrateMode("off") == .off)
        #expect(SocketControlSettings.migrateMode("cmux_only") == .cmuxOnly)
        #expect(SocketControlSettings.migrateMode("ALLOW-ALL") == .allowAll)
        // Legacy aliases.
        #expect(SocketControlSettings.migrateMode("notifications") == .automation)
        #expect(SocketControlSettings.migrateMode("full") == .allowAll)
        // Unknown falls back to the default.
        #expect(SocketControlSettings.migrateMode("bogus") == .cmuxOnly)
    }

    @Test func effectiveModeHonorsEnableOverride() {
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["CMUX_SOCKET_ENABLE": "0"]
            ) == .off
        )
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .off,
                environment: ["CMUX_SOCKET_ENABLE": "1"]
            ) == .cmuxOnly
        )
    }

    @Test func effectiveModeHonorsModeOverride() {
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .cmuxOnly,
                environment: ["CMUX_SOCKET_MODE": "allowall"]
            ) == .allowAll
        )
    }

    @Test func effectiveModeFallsBackToUserMode() {
        #expect(
            SocketControlSettings.effectiveMode(userMode: .automation, environment: [:]) == .automation
        )
    }

    @Test func truthyParsing() {
        for value in ["1", "true", "YES", "on"] {
            #expect(SocketControlSettings.isTruthy(value))
        }
        for value in ["0", "false", "", "nope"] {
            #expect(!SocketControlSettings.isTruthy(value))
        }
    }

    @Test func taggedDevBuildDetection() {
        #expect(SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.cmuxterm.app.debug.my-tag"))
        #expect(!SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.cmuxterm.app.debug"))
        #expect(!SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.cmuxterm.app"))
    }

    @Test func untaggedDebugLaunchIsBlockedOnlyForBareDebugBundle() {
        // Bare debug bundle, no tag, not under test => blocked.
        #expect(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
        // XCUITest launches the app as a separate process without XCTest env vars,
        // so any CMUX_UI_TEST_ marker must bypass blocking for a bare debug bundle.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_UI_TEST_RUN": "1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
        // Tagged debug bundle => allowed.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug.tag",
                isDebugBuild: true
            )
        )
        // Release build => never blocked.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false
            )
        )
    }

    @Test func socketPathHonorsOverrideForTaggedDevWhenAllowed() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-custom.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.tag",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path == "/tmp/cmux-custom.sock")
    }
}
