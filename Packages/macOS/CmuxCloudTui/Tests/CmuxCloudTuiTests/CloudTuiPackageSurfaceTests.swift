import Foundation
import Testing
import CmuxCloudTui

/// Exercises the transport through its public surface only, the way the app
/// target consumes it after the move.
@Suite struct CloudTuiPackageSurfaceTests {
    @Test func shellQuoteLeavesSafeWordsAndQuotesTheRest() {
        #expect(CloudTuiCommandLine.shellQuote("") == "''")
        #expect(CloudTuiCommandLine.shellQuote("/tmp/cmux.sock") == "/tmp/cmux.sock")
        #expect(CloudTuiCommandLine.shellQuote("it's") == "'it'\\''s'")
    }

    /// A line terminator must never be left bare: the shell would end the
    /// command there and run the rest as a second command.
    @Test(arguments: ["abc\n", "abc\r", "abc\r\n", "a\nb"])
    func shellQuoteQuotesLineTerminators(value: String) {
        #expect(CloudTuiCommandLine.shellQuote(value) == "'\(value)'")
    }

    @Test func gridRejectsDimensionsOutsideTheSupportedRange() {
        #expect(CloudTuiManualIOGrid(columns: 1, rows: 24) == nil)
        #expect(CloudTuiManualIOGrid(columns: 80, rows: 10_001) == nil)
        #expect(CloudTuiManualIOGrid(columns: 80, rows: 24)?.columns == 80)
    }

    @Test func manualInputCommandsOptOutOfControlReceipts() {
        let commands = CloudTuiManualIOCommand()
        #expect(commands.input(surfaceID: 7, bytes: Data("x".utf8))["no_reply"] as? Bool == true)
        #expect(commands.namedKey(surfaceID: 7, key: "enter")["no_reply"] as? Bool == true)
        #expect(commands.resize(surfaceID: 7, columns: 80, rows: 24)["no_reply"] == nil)
    }

    @Test func resizeSchedulerKeepsOneRequestInFlightAndSendsTheNewestNext() throws {
        let small = try #require(CloudTuiManualIOGrid(columns: 80, rows: 24))
        let medium = try #require(CloudTuiManualIOGrid(columns: 100, rows: 30))
        let large = try #require(CloudTuiManualIOGrid(columns: 120, rows: 40))
        var scheduler = CloudTuiManualIOResizeScheduler()
        #expect(scheduler.sample(small, canSend: true) == small)
        #expect(scheduler.sample(medium, canSend: true) == nil)
        #expect(scheduler.sample(large, canSend: true) == nil)
        #expect(scheduler.acknowledge(canSend: true) == large)
        #expect(scheduler.lastAcknowledged == small)
    }

    @Test func legacyParserReadsNothingFromMalformedData() {
        #expect(CloudTuiLegacySnapshotParser().protocolVersion(from: Data("not json".utf8)) == nil)
    }

    /// The package policy preserves old identify-capability fallbacks while
    /// rejecting modern daemons that cannot frame incomplete VT sequences.
    @Test func staleReplayCapabilityPolicyKeepsLegacyPeersCompatible() throws {
        let commands = CloudTuiManualIOCommand()
        let current = try #require(commands.setClientInfo(name: "test", kind: "native")["capabilities"] as? [String])
        #expect(!commands.isStaleReplayDaemon(capabilities: current))
        #expect(commands.isStaleReplayDaemon(capabilities: current.filter {
            $0 != CloudTuiManualIOCommand.terminalPendingSequenceCapability
        }))
        #expect(!commands.isStaleReplayDaemon(capabilities: []))
        #expect(!commands.isStaleReplayDaemon(capabilities: ["future-unknown-feature"]))
        for capability in [
            CloudTuiManualIOCommand.viewAttachmentLeaseCapability,
            CloudTuiManualIOCommand.viewAttachmentDetachCapability,
            CloudTuiManualIOCommand.sharedSizingCapability,
            CloudTuiManualIOCommand.sizingViewDetachCapability,
            "terminal-color-overrides-v1",
            "attach-identity-v1",
            "attach-initial-size",
        ] {
            #expect(commands.isStaleReplayDaemon(capabilities: [capability]))
            #expect(!commands.isStaleReplayDaemon(capabilities: [
                capability, CloudTuiManualIOCommand.terminalPendingSequenceCapability,
            ]))
        }
    }
}
