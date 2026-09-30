import CmuxNextDaemon
import Testing

/// What a daemon can do for the app, from its `identify` or its refusal.
/// The capability lists are the ones real builds report: the Cloud image
/// `tui3412812` (read from a dev machine on 2026-09-30) and the pinned
/// cmux-next build.
@Suite struct DaemonCompatibilityTests {
    /// Capabilities of cmux-tui 3412812 (the Cloud image this branch bakes).
    static let cloudImage3412812: [String] = [
        "attach-identity-v1", "attach-initial-size", "browser-pointer-frame-guard-v1", "browser-provider-v1",
        "clear-history-key-v1", "clear-history-v1", "client-focus-v1", "creation-attempt-keys-v1",
        "creation-receipts-v1", "creation-selector-fallbacks-v1", "daemon-handoff-force-v1", "frontend-journal-v1",
        "layout-undo-v1", "machine-listening-tcp-v1", "machine-usage-v1", "provider-managed-workspace-authority-v2",
        "server-stats-v1", "session-journal-v1", "surface-subscribe-filter", "tab-workspace-move-v1",
        "terminal-color-overrides-v1", "terminal-image-paste-v1", "view-attachment-detach-v1",
        "view-attachment-lease-v1", "viewport-column-resize-v1", "viewport-splits-v1", "workspace-registry-v1",
    ]

    static func identity(_ capabilities: [String], version: String = "0.1.0", commit: String? = "3412812eae76") -> DaemonIdentity {
        DaemonIdentity(version: version, buildCommit: commit, capabilities: capabilities, session: "cloud",
                       registryID: "D3902657-A59D-47E7-AE88-84EEFA589F4B", generation: DaemonGeneration(rawValue: "g1"))
    }

    @Test func sessionIdentityIsTheRegistryUUIDNotTheBootGeneration() {
        let compat = DaemonCompatibility(identity: Self.identity(Self.cloudImage3412812))
        #expect(compat.sessionID == "d3902657-a59d-47e7-ae88-84eefa589f4b")
        #expect(compat.sessionName == "cloud")
        #expect(compat.protocolVersion == 12)
        #expect(DaemonCompatibility(refusal: .unsupportedProtocol(11))?.sessionID == nil)
    }

    @Test func cloudImageDaemonIsLimitedAndNamesEveryMissingFeature() {
        let compat = DaemonCompatibility(identity: Self.identity(Self.cloudImage3412812))
        #expect(compat.level == .limited)
        #expect(compat.missingRequired.isEmpty)
        #expect(compat.missingOptional == DaemonCapabilities.optional)
        #expect(compat.buildCommit == "3412812eae76")
    }

    @Test func daemonWithEveryCapabilityIsCurrent() {
        let compat = DaemonCompatibility(identity: Self.identity(DaemonCapabilities.required + DaemonCapabilities.optional))
        #expect(compat.level == .current)
        #expect(compat.missingOptional.isEmpty)
    }

    @Test func personalStateOnTheHomeSessionIsNotAMissingRemoteFeature() {
        let notNeeded = Set(DaemonCapabilities.homeOnly + DaemonCapabilities.personalOnHome)
        let compat = DaemonCompatibility(identity: Self.identity(Self.cloudImage3412812), notNeeded: notNeeded)
        #expect(compat.level == .limited)
        #expect(!compat.missingOptional.contains(DaemonCapabilities.workspaceGroups))
        #expect(!compat.missingOptional.contains(DaemonCapabilities.savedTabGroups))
        #expect(!compat.missingOptional.contains(DaemonCapabilities.profiles))
        let personalOnly = DaemonCapabilities.required + DaemonCapabilities.optional.filter { !notNeeded.contains($0) }
        #expect(DaemonCompatibility(identity: Self.identity(personalOnly), notNeeded: notNeeded).level == .current)
    }

    @Test func refusedHandshakeIsIncompatible() {
        let missing = DaemonCompatibility(refusal: .missingCapabilities(["view-attachment-detach-v1"]))
        #expect(missing?.level == .incompatible)
        #expect(missing?.missingRequired == ["view-attachment-detach-v1"])
        #expect(DaemonCompatibility(refusal: .unsupportedProtocol(11))?.level == .incompatible)
        #expect(DaemonCompatibility(refusal: .wrongApp("tmux"))?.level == .incompatible)
    }

    @Test func transientFailuresSayNothingAboutCompatibility() {
        #expect(DaemonCompatibility(refusal: .timedOut("identify")) == nil)
        #expect(DaemonCompatibility(refusal: .connectFailed(path: "/tmp/x.sock", errno: 2)) == nil)
    }

    @Test func versionLabelShowsShortCommit() {
        let compat = DaemonCompatibility(identity: Self.identity([], commit: "3412812eae761215cb3fb99ec7d4a078ecd296dc"))
        #expect(compat.versionLabel == "0.1.0 (3412812eae76)")
        #expect(DaemonCompatibility(identity: Self.identity([], commit: nil)).versionLabel == "0.1.0")
    }
}
