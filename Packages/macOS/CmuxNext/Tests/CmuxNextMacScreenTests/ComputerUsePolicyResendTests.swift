// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// cmux Remote's Computer Use worker starts only once the app's policy reaches it. At launch the
/// daemon may not be connected yet, and a daemon can restart: the same, unchanged policy must go
/// to the new connection. Before the fix the app followed an `Equatable` policy, so an unchanged
/// policy never woke the loop again and the worker waited for it forever
/// (`cmux computer-use status`: "waiting for the cmux app's Computer Use settings").
@Suite struct ComputerUsePolicyResendTests {
    final class Connection {}

    static func policy(_ mode: String) -> CmuxRemoteComputerUsePolicy {
        CmuxRemoteComputerUsePolicy(policy: Data(#"{"mode":"\#(mode)"}"#.utf8), cursorAnimates: true, cursorSpeed: 1)
    }

    @Test func aNewConnectionGetsTheSamePolicyAgain() {
        let first = Connection(), second = Connection()
        var resend = ComputerUsePolicyResend()
        let full = Self.policy("fullAccess")
        #expect(resend.shouldSend(full, connection: first))
        resend.record(full, connection: first, taken: true)
        // The same connection already has it.
        #expect(!resend.shouldSend(full, connection: first))
        // The daemon restarted: the unchanged policy goes again.
        #expect(resend.shouldSend(full, connection: second))
    }

    /// A reconnect frees the old connection, and the new one may get the same address; the
    /// policy must still go to it (an address key would have skipped it).
    @Test func aFreedConnectionNeverMatchesTheNextOne() {
        var resend = ComputerUsePolicyResend()
        let full = Self.policy("fullAccess")
        do {
            let gone = Connection()
            resend.record(full, connection: gone, taken: true)
        }
        #expect(resend.shouldSend(full, connection: Connection()))
    }

    @Test func aRefusedSendIsTriedAgainAndAChangeAlwaysGoes() {
        let connection = Connection()
        var resend = ComputerUsePolicyResend()
        let full = Self.policy("fullAccess")
        resend.record(full, connection: connection, taken: false)
        #expect(resend.shouldSend(full, connection: connection))
        resend.record(full, connection: connection, taken: true)
        #expect(resend.shouldSend(Self.policy("lookOnly"), connection: connection))
    }
}
