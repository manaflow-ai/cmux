import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch command rejection reason")
struct AgentLaunchCommandRejectionReasonTests {
    /// A rejected capture must keep the ground it was rejected on. Storing only
    /// `source: "rejected"` records a verdict nobody can act on: the CLI treats
    /// it as no evidence at all and silently downgrades restore.
    @Test func rejectionGroundSurvivesAStoreRoundTrip() throws {
        let stored = """
        {
          "arguments": [],
          "launcher": "codex",
          "source": "rejected",
          "rejectionReason": "sanitizerRejectedArgv",
          "capturedAt": 1
        }
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        #expect(object["source"] as? String == "rejected")
        #expect(object["rejectionReason"] as? String == "sanitizerRejectedArgv")
    }

    /// The hand-written decoder has to read every stored field, not only the
    /// ones that existed when it was written: `externalLauncher` is how resume
    /// replays an agent through its user-declared launcher, and a decoder that
    /// skipped it would drop the launcher on the next store rewrite.
    @Test func decodingKeepsTheExternalLauncher() throws {
        let stored = """
        {"arguments": ["claude"], "launcher": "claude", "externalLauncher": "teamclaude"}
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        #expect(command.externalLauncher == "teamclaude")

        let rejected = AgentLaunchCommand(
            rejectedOn: .argvUnavailable,
            launcher: "claude",
            externalLauncher: "teamclaude"
        )
        let roundTripped = try JSONDecoder().decode(
            AgentLaunchCommand.self,
            from: JSONEncoder().encode(rejected)
        )
        #expect(roundTripped.externalLauncher == "teamclaude")
        #expect(roundTripped.rejectionReason == .argvUnavailable)
    }

    /// A ground written by a newer cmux build has to survive an older build
    /// reading the store and writing it back: the store is rewritten in full on
    /// every mutation, so a token that decodes to a fallback is a token this
    /// build silently replaces with the wrong reason.
    @Test func groundFromANewerBuildRoundTripsUnchanged() throws {
        let stored = """
        {"arguments": [], "source": "rejected", "rejectionReason": "groundThisBuildDoesNotKnow"}
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        #expect(object["rejectionReason"] as? String == "groundThisBuildDoesNotKnow")
    }

    /// A record cannot say "rejected, here is why" and still hand a reader a
    /// launch it could replay. The reason is only reachable through the rejected
    /// initializer, which fixes `arguments` to empty, and neither property can
    /// be reassigned afterwards.
    @Test func aRejectionGroundNeverSitsBesideAUsableArgv() {
        let rejected = AgentLaunchCommand(
            rejectedOn: .sanitizerRejectedArgv,
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            source: "rejected"
        )
        #expect(rejected.arguments.isEmpty)
        #expect(rejected.rejectionReason == .sanitizerRejectedArgv)

        let captured = AgentLaunchCommand(
            launcher: "codex",
            arguments: ["/usr/local/bin/codex", "--yolo"],
            source: "process"
        )
        #expect(captured.rejectionReason == nil)

        // Repair paths mutate a record's argv in place, so the invariant has to
        // hold after construction too.
        var repaired = rejected
        repaired.arguments = ["/usr/local/bin/codex", "resume"]
        #expect(repaired.rejectionReason == nil)
        #expect(repaired.isRejectedCapture == false)
    }

    /// The one combination cmux never writes, if a hand-edited or foreign record
    /// carries it: the argv is the actionable half, so it survives and the
    /// ground that contradicts it does not reach `sessions --json`.
    @Test func aGroundBesideAUsableArgvDoesNotSurviveDecoding() throws {
        let stored = """
        {
          "arguments": ["/usr/local/bin/codex", "--yolo"],
          "source": "rejected",
          "rejectionReason": "sanitizerRejectedArgv"
        }
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        #expect(command.arguments == ["/usr/local/bin/codex", "--yolo"])
        #expect(command.rejectionReason == nil)
        #expect(command.source == nil)
        #expect(command.isRejectedCapture == false)

        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        // The argv is what the rewrite must not lose: dropping the contradicting
        // ground is the point, dropping the launch would be a new defect.
        #expect(object["arguments"] as? [String] == ["/usr/local/bin/codex", "--yolo"])
        #expect(object["rejectionReason"] == nil)
        #expect(object["source"] == nil)
    }

    /// Records written before the field existed must still decode, and must not
    /// grow the key when the capture produced a usable argv.
    @Test func recordWithoutARejectionGroundStillDecodes() throws {
        let stored = """
        {"arguments": ["/usr/local/bin/codex"], "source": "process"}
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        #expect(command.arguments == ["/usr/local/bin/codex"])
        #expect(command.source == "process")

        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        #expect(object["rejectionReason"] == nil)
    }

    @Test func typedUnavailableGroundWinsOverLegacyRejectedMarker() throws {
        let stored = """
        {
          "arguments": [],
          "source": "rejected",
          "rejectionReason": "argvUnavailable"
        }
        """
        let command = try JSONDecoder().decode(
            AgentLaunchCommand.self,
            from: Data(stored.utf8)
        )

        #expect(command.rejectionReason == .argvUnavailable)
        #expect(command.isRejectedCapture == false)
    }

    @Test(arguments: [
        AgentLaunchCaptureRejectionReason.nativeProcessDoesNotDescribeKind,
        AgentLaunchCaptureRejectionReason.argvLooksLikeShellWrapper,
        AgentLaunchCaptureRejectionReason.argvUnavailable,
    ])
    func pidFallbackGroundsKeepEnvironmentFallbackEligible(
        _ reason: AgentLaunchCaptureRejectionReason
    ) {
        let command = AgentLaunchCommand(
            rejectedOn: reason,
            launcher: "gemini",
            environment: ["GEMINI_CLI_HOME": "/tmp/gemini"],
            source: "environment"
        )

        #expect(command.rejectionReason == reason)
        #expect(command.isRejectedCapture == false)
        #expect(reason.isPositiveCaptureRejection == false)
    }

    @Test(arguments: [
        AgentLaunchCaptureRejectionReason.launcherDoesNotDescribeKind,
        AgentLaunchCaptureRejectionReason.argvDecodeFailed,
        AgentLaunchCaptureRejectionReason.sanitizerRejectedArgv,
    ])
    func explicitCaptureGroundsStillFailClosed(
        _ reason: AgentLaunchCaptureRejectionReason
    ) {
        let command = AgentLaunchCommand(
            rejectedOn: reason,
            launcher: "gemini",
            environment: ["GEMINI_CLI_HOME": "/tmp/gemini"],
            source: "rejected"
        )

        #expect(command.rejectionReason == reason)
        #expect(command.isRejectedCapture)
        #expect(reason.isPositiveCaptureRejection)
    }

    @Test func decodeFailureHasAStableForwardCompatibleToken() throws {
        let reason = AgentLaunchCaptureRejectionReason.argvDecodeFailed
        let encoded = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(
            AgentLaunchCaptureRejectionReason.self,
            from: encoded
        )
        #expect(decoded == reason)
        #expect(reason.rawValue == "argvDecodeFailed")
    }
}
