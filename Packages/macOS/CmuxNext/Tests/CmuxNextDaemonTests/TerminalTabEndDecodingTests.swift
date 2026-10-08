import Foundation
import Testing
@testable import CmuxNextDaemon

/// R41: the tab carries whether its shell runs and why a dead one ended, so the
/// banner never says "Process exited" for a host loss or a pending adoption.
@Suite struct TerminalTabEndDecodingTests {
    private func tab(_ json: String) throws -> TabSnapshot {
        try JSONDecoder().decode(TabSnapshot.self, from: Data(json.utf8))
    }

    @Test func adoptingTerminalIsNotDead() throws {
        let tab = try tab(#"{"surface":4,"kind":"pty","dead":false,"terminal_state":"adopting"}"#)
        #expect(tab.terminalState == .adopting)
        #expect(!tab.dead)
        #expect(tab.end == nil)
    }

    @Test func unadoptableTerminalCarriesItsRecordVersion() throws {
        let tab = try tab(#"{"surface":4,"dead":false,"terminal_state":"unadoptable","host_record_version":99}"#)
        #expect(tab.terminalState == .unadoptable)
        #expect(tab.hostRecordVersion == 99)
    }

    @Test func processExitAndHostLossAreDistinct() throws {
        let exited = try tab(#"{"surface":4,"dead":true,"terminal_state":"exited","end":{"kind":"exited","code":3}}"#)
        #expect(exited.end == TerminalTabEnd(kind: .exited, code: 3))
        let lost = try tab(
            #"{"surface":4,"dead":true,"terminal_state":"exited","end":{"kind":"host_lost","reason":"died_without_exit_status","detail":"x"}}"#
        )
        #expect(lost.end?.kind == .hostLost)
        #expect(lost.end?.reason == .diedWithoutExitStatus)
    }

    @Test func unknownFutureValuesNeverFailTheTab() throws {
        let tab = try tab(
            #"{"surface":4,"dead":true,"terminal_state":"hibernating","end":{"kind":"host_lost","reason":"new_reason"}}"#
        )
        #expect(tab.terminalState == nil)
        #expect(tab.end?.reason == .other)
    }

    /// cx-0tgl LA: a host loss names its recorded cause (the signal's sender,
    /// or the host's crash).
    @Test func aHostLossCarriesItsCause() throws {
        let lost = try tab(
            #"{"surface":4,"dead":true,"end":{"kind":"host_lost","reason":"dead_before_adoption","cause":"SIGTERM from pid 9 (bash, parent 1 launchd)"}}"#
        )
        #expect(lost.end?.cause == "SIGTERM from pid 9 (bash, parent 1 launchd)")
    }

    @Test func olderDaemonsOmitTheFields() throws {
        let tab = try tab(#"{"surface":4,"dead":true}"#)
        #expect(tab.terminalState == nil)
        #expect(tab.end == nil)
    }
}
