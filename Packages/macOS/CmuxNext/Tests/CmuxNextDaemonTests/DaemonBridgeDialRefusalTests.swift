@testable import CmuxNextDaemon
import Foundation
import Testing

/// A refused dial line keeps its stage (`error_code`) and its detail (`error_detail`, bounded), so
/// a remote view's end reason says why the dial failed.
@Suite struct DaemonBridgeDialRefusalTests {
    private static func refusal(_ line: String) -> String? {
        do {
            try DaemonBridge.check(Data(line.utf8))
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test func aRefusalNamesItsStageAndDetail() {
        let line = #"{"ok":false,"error_code":"relay","error_detail":"no relay answered in 10s"}"#
        #expect(Self.refusal(line) == "the link refused the dial: relay: no relay answered in 10s")
    }

    @Test func aRefusalWithoutDetailNamesOnlyItsStage() {
        #expect(Self.refusal(#"{"ok":false,"error_code":"ticket"}"#) == "the link refused the dial: ticket")
        #expect(Self.refusal(#"{"ok":true}"#) == nil)
    }

    @Test func aLongDetailIsCut() throws {
        let detail = String(repeating: "x", count: 900)
        let reason = try #require(Self.refusal(#"{"ok":false,"error_code":"handshake","error_detail":"\#(detail)"}"#))
        #expect(reason == "the link refused the dial: handshake: " + String(repeating: "x", count: DaemonBridge.maxDetailCharacters))
    }

    /// A progress line before the dial line gives its text; the dial line and any other line give none.
    @Test func aProgressLineGivesItsTextAndTheDialLineNone() {
        let line = #"{"progress":{"stage":"waking","text":"Waking up the machine, about 25 s left","eta_ms":25000}}"#
        #expect(DaemonBridge.progressText(Data(line.utf8)) == "Waking up the machine, about 25 s left")
        #expect(DaemonBridge.progressText(Data(#"{"ok":true,"route":"carrier"}"#.utf8)) == nil)
        #expect(DaemonBridge.progressText(Data(#"{"progress":{"text":""}}"#.utf8)) == nil)
        #expect(DaemonBridge.progressText(Data("not json".utf8)) == nil)
    }
}
