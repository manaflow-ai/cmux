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
        #expect(resend.shouldSend(full, connection: ObjectIdentifier(first)))
        resend.record(full, connection: ObjectIdentifier(first), taken: true)
        // The same connection already has it.
        #expect(!resend.shouldSend(full, connection: ObjectIdentifier(first)))
        // The daemon restarted: the unchanged policy goes again.
        #expect(resend.shouldSend(full, connection: ObjectIdentifier(second)))
        withExtendedLifetime((first, second)) {}
    }

    @Test func aRefusedSendIsTriedAgainAndAChangeAlwaysGoes() {
        let connection = Connection()
        var resend = ComputerUsePolicyResend()
        let full = Self.policy("fullAccess")
        resend.record(full, connection: ObjectIdentifier(connection), taken: false)
        #expect(resend.shouldSend(full, connection: ObjectIdentifier(connection)))
        resend.record(full, connection: ObjectIdentifier(connection), taken: true)
        #expect(resend.shouldSend(Self.policy("lookOnly"), connection: ObjectIdentifier(connection)))
        withExtendedLifetime(connection) {}
    }
}
