import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch replay planning")
struct AgentLaunchReplayPlannerTests {
    private let planner = AgentLaunchReplayPlanner()

    @Test func nativeGeminiCaptureThatLosesScriptIdentityUsesCanonicalReplay() {
        #expect(
            planner.plan(
                kind: "gemini",
                launcher: "gemini",
                executablePath: "/Users/alice/.hermes/node/bin/node",
                capturedArguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                    "/Users/alice/.bun/bin/gemini",
                    "--yolo",
                ],
                sanitizedArguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                ],
                evidence: .nativeProcess,
                hasSelectedEnvironment: false
            ) == .canonical
        )
    }

    @Test func validNativeCaptureKeepsSanitizedArguments() {
        let sanitized = ["/opt/homebrew/bin/codex", "--yolo"]
        #expect(
            planner.plan(
                kind: "codex",
                launcher: "codex",
                executablePath: "/opt/homebrew/bin/codex",
                capturedArguments: ["/opt/homebrew/bin/codex", "--yolo", "prompt"],
                sanitizedArguments: sanitized,
                evidence: .nativeProcess,
                hasSelectedEnvironment: false
            ) == .captured(arguments: sanitized, evidence: .nativeProcess)
        )
    }

    @Test func wrapperCaptureKeepsWrapperArguments() {
        let sanitized = ["cmux", "claude-teams", "--permission-mode", "bypassPermissions"]
        #expect(
            planner.plan(
                kind: "claude",
                launcher: "claudeTeams",
                executablePath: "cmux",
                capturedArguments: sanitized,
                sanitizedArguments: sanitized,
                evidence: .wrapperEnvironmentLauncher,
                hasSelectedEnvironment: false
            ) == .captured(arguments: sanitized, evidence: .wrapperEnvironmentLauncher)
        )
    }

    @Test func explicitlyNonRestorableCaptureStaysRejected() {
        #expect(
            planner.plan(
                kind: "opencode",
                launcher: "omx",
                executablePath: "cmux",
                capturedArguments: ["cmux", "omx"],
                sanitizedArguments: nil,
                evidence: .wrapperEnvironmentLauncher,
                hasSelectedEnvironment: false
            ) == .rejected
        )
    }

    @Test func unsupportedMissingCaptureStaysUnavailable() {
        #expect(
            planner.plan(
                kind: "gemini",
                launcher: "gemini",
                executablePath: nil,
                capturedArguments: nil,
                sanitizedArguments: nil,
                evidence: .unavailable,
                hasSelectedEnvironment: false
            ) == .unavailable
        )
    }

    @Test func codexRetainsHistoricalCanonicalFallbackWithoutCapture() {
        #expect(
            planner.plan(
                kind: "codex",
                launcher: "codex",
                executablePath: nil,
                capturedArguments: nil,
                sanitizedArguments: nil,
                evidence: .unavailable,
                hasSelectedEnvironment: false
            ) == .canonical
        )
    }

    @Test func exactEnvironmentMarkerCanRecoverFromTruncatedCapture() {
        #expect(
            planner.plan(
                kind: "gemini",
                launcher: "gemini",
                executablePath: "/Users/alice/.hermes/node/bin/node",
                capturedArguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                ],
                sanitizedArguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                ],
                evidence: .exactEnvironmentLauncher,
                hasSelectedEnvironment: false
            ) == .canonical
        )
    }

    @Test func selectedEnvironmentPreservesFallbackWhenArgumentsAreUnavailable() {
        #expect(
            planner.plan(
                kind: "claude",
                launcher: "claude",
                executablePath: nil,
                capturedArguments: nil,
                sanitizedArguments: nil,
                evidence: .unavailable,
                hasSelectedEnvironment: true
            ) == .canonical
        )
    }
}
