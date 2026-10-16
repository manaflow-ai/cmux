import Foundation
import Testing

@testable import CmuxCEF

@Suite("CEF password and passkey parity")
struct CEFPasswordParityTests {
    @Test("password metadata parser keeps rows and Chromium epoch dates")
    func parsesMetadata() throws {
        let json = #"""
        {
          "passwords": [{
            "id": "42",
            "site": "Example",
            "url": "https://example.com/login",
            "username": "alice",
            "created": 1700000000000,
            "last_used": 1700000000100,
            "times_used": 3,
            "weak": true,
            "reused": false
          }, {"site": "missing-id"}],
          "exceptions": [{"id": "7", "site": "https://never.example"}, {"site": "missing-id"}]
        }
        """#

        let list = try #require(ChromiumPasswordList.parse(json))
        #expect(list.passwords.count == 1)
        #expect(list.passwords[0].id == "42")
        #expect(list.passwords[0].username == "alice")
        #expect(list.passwords[0].timesUsed == 3)
        #expect(list.passwords[0].isWeak)
        #expect(!list.passwords[0].isReused)
        #expect(list.passwords[0].created == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(list.passwords[0].lastUsed == Date(timeIntervalSince1970: 1_700_000_000.1))
        #expect(list.exceptions == [ChromiumPasswordList.Exception(id: "7", site: "https://never.example")])
    }

    @Test("metadata parsers fail closed for malformed or secret-shaped replies")
    func rejectsMalformedReplies() {
        #expect(ChromiumPasswordList.parse("not json") == nil)
        #expect(ChromiumPasskey.parse("not json") == nil)
        #expect(ChromiumPasskey.parse(#"[{"rp_id":"example.com"}]"#) == [])
        #expect(ChromiumPasswordList.parse(#"{"passwords":"secret"}"#)?.passwords == [])
    }

    @Test("passkey parser only returns metadata with a credential delete key")
    func parsesPasskeys() throws {
        let json = #"""
        [
          {"rp_id":"example.com","credential_id":"AQID","user_name":"alice","user_display_name":"Alice"},
          {"rp_id":"ignored","credential_id":""}
        ]
        """#
        let rows = try #require(ChromiumPasskey.parse(json))
        #expect(rows == [ChromiumPasskey(credentialID: "AQID", relyingParty: "example.com", userName: "alice", userDisplayName: "Alice")])
    }

    @Test("password write result parsers preserve conflict indices")
    func parsesWriteResults() throws {
        let imported = try #require(ChromiumPasswordWriteResult.parse(#"{"added":2,"duplicate":1,"conflict":2,"rejected":1,"conflicts":[3,5]}"#))
        #expect(imported == ChromiumPasswordWriteResult(added: 2, duplicate: 1, conflict: 2, rejected: 1, conflictIndices: [3, 5]))
        #expect(!imported.storeFailed)
        let replaced = try #require(ChromiumPasswordReplaceResult.parse(#"{"updated":2,"missing":1,"rejected":0}"#))
        #expect(replaced == ChromiumPasswordReplaceResult(updated: 2, missing: 1, rejected: 0))
        #expect(ChromiumPasswordWriteResult.parse(#"{"added":2}"#) == nil)
    }

    @Test("password rows use the documented 72-byte ABI and zero after copy")
    func rowLayoutAndZeroing() {
        var copied = false
        let secret = Array("hunter2".utf8)
        secret.withUnsafeBytes { secretBytes in
            let rows = ChromiumPasswordRows([
                (
                    url: "https://example.com/login",
                    signonRealm: "https://example.com/",
                    username: "alice",
                    password: UnsafeRawBufferPointer(secretBytes),
                    created: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]) { copied = true }

            #expect(ChromiumPasswordRows.stride == 72)
            #expect(rows.count == 1)
            let row = rows.rows
            #expect(row.load(fromByteOffset: 8, as: Int.self) == "https://example.com/login".utf8.count)
            #expect(row.load(fromByteOffset: 40, as: Int.self) == "alice".utf8.count)
            #expect(row.load(fromByteOffset: 56, as: Int.self) == secret.count)
            #expect(row.load(fromByteOffset: 64, as: Int64.self) == 13_344_473_600_000_000)
            rows.copied()
            #expect(copied)
            #expect((0..<ChromiumPasswordRows.stride).allSatisfy { row.load(fromByteOffset: $0, as: UInt8.self) == 0 })
        }
    }

    @Test("password fill policy sends each transition, including profile disable")
    func fillStateTransitions() {
        var state = PasswordFillState()
        #expect(PasswordFillPolicy.fills(agentDriven: false, profileAllows: true))
        #expect(!PasswordFillPolicy.fills(agentDriven: true, profileAllows: true))
        #expect(state.nextSwitchValue(agentDriven: false) == 1)
        #expect(state.nextSwitchValue(agentDriven: false) == nil)
        let disabled = state.setAllowedByProfile(false)
        #expect(disabled)
        #expect(state.nextSwitchValue(agentDriven: false) == 0)
        #expect(state.nextSwitchValue(agentDriven: false) == nil)
        #expect(state.nextSwitchValue(agentDriven: true) == nil)
        let enabled = state.setAllowedByProfile(true)
        #expect(enabled)
        #expect(state.nextSwitchValue(agentDriven: false) == 1)
    }

}
