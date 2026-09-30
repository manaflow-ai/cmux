import Foundation
import Testing
@testable import CmuxNextMobile

struct DaemonLanePolicyTests {
    let policy = DaemonLanePolicy(deviceID: "phone-1")

    private func verdict(_ json: String) -> DaemonLanePolicy.Verdict {
        policy.evaluate(Data(json.utf8))
    }

    private func refusal(_ json: String) -> [String: Any]? {
        guard case .refuse(let data) = verdict(json) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func forwardsTerminalAndTreeCommands() {
        for cmd in ["identify", "list-workspaces", "attach-surface", "send", "set-client-sizing",
                    "create-terminal", "close-workspace", "subscribe", "resize-attached-view"] {
            #expect(verdict(#"{"id":"r1","cmd":"\#(cmd)"}"#) == .forward, "\(cmd)")
        }
    }

    @Test func refusesLocalAdminAndProviderCommands() throws {
        for cmd in ["shutdown-daemon", "pairing-response", "reload-config", "detach-client",
                    "register-browser-provider", "mark-workspaces-provider-managed",
                    "close-provider-managed-workspace", "set-default-colors", "mint-terminal-renderer",
                    "url-open-claim", "journal-frontend-event", "some-future-command"] {
            let response = try #require(refusal(#"{"id":"r7","cmd":"\#(cmd)"}"#), "\(cmd)")
            #expect(response["ok"] as? Bool == false)
            #expect(response["id"] as? String == "r7")
            #expect(response["error_code"] as? String == "forbidden")
        }
    }

    /// `run` and `create-surface-with-receipt` start an arbitrary program
    /// on the Mac without a terminal the user drives; the phone never sends
    /// them (remote-relay-authorization.md rules 2-4).
    @Test func refusesNonInteractiveProgramStarts() throws {
        for line in [#"{"id":1,"cmd":"run","argv":["/bin/sh","-c","id"]}"#,
                     #"{"id":2,"cmd":"run","command":"id"}"#,
                     #"{"id":3,"cmd":"create-surface-with-receipt","operation":"pane.split","origin":"x","receipt":"r","argv":["id"]}"#] {
            #expect(refusal(line)?["error_code"] as? String == "forbidden", "\(line)")
        }
    }

    /// Terminal creation carries no program, directory or environment from
    /// the phone (`env` alone can run code through DYLD_* or BASH_ENV), and
    /// an unknown field is refused, not ignored: a daemon field added later
    /// must be reviewed before a phone may set it.
    @Test func refusesCommandBearingAndUnknownCreationParams() throws {
        for line in [#"{"id":1,"cmd":"create-terminal","key":"w","argv":["id"]}"#,
                     #"{"id":2,"cmd":"create-terminal","key":"w","command":"id"}"#,
                     #"{"id":3,"cmd":"create-terminal","key":"w","cwd":"/"}"#,
                     #"{"id":4,"cmd":"create-terminal","key":"w","env":{"BASH_ENV":"/tmp/x"}}"#,
                     #"{"id":5,"cmd":"new-tab","pane":1,"env":{"DYLD_INSERT_LIBRARIES":"/tmp/x.dylib"}}"#,
                     #"{"id":6,"cmd":"new-tab","pane":1,"cwd":"/private"}"#,
                     #"{"id":7,"cmd":"split","pane":1,"dir":"right","env":{"A":"b"}}"#,
                     #"{"id":8,"cmd":"new-pane","pane":1,"cwd":"/"}"#,
                     #"{"id":9,"cmd":"new-pane-right","pane":1,"env":{"A":"b"}}"#,
                     #"{"id":10,"cmd":"create-terminal","key":"w","shell":"/bin/zsh"}"#,
                     #"{"id":11,"cmd":"new-tab","pane":1,"terminal_id":"term_0123"}"#] {
            let response = try #require(refusal(line), "\(line)")
            #expect(response["error_code"] as? String == "forbidden", "\(line)")
        }
    }

    /// Exactly what the iOS `CmuxTUIControl` sends still passes.
    @Test func forwardsThePhonesOwnCreationRequests() {
        for line in [#"{"id":1,"cmd":"new-screen","workspace":3,"cols":80,"rows":24}"#,
                     #"{"id":2,"cmd":"new-tab","pane":4,"cols":80,"rows":24}"#,
                     #"{"id":3,"cmd":"split","pane":4,"dir":"down","cols":80,"rows":24}"#,
                     #"{"id":4,"cmd":"create-workspace","name":"phone"}"#,
                     #"{"id":5,"cmd":"create-terminal","key":"ws_1","cols":80,"rows":24,"name":"t"}"#,
                     #"{"id":6,"cmd":"new-workspace","name":"n","cols":80,"rows":24}"#,
                     #"{"id":7,"cmd":"create-terminal","key":"ws_1","origin":"ios","mutation_id":"m1","expected_generation":"g"}"#] {
            #expect(verdict(line) == .forward, "\(line)")
        }
    }

    @Test func personalProjectionIsPerDevice() {
        let own = #"{"id":1,"cmd":"put-frontend-projection","frontend":"ios","scope":"personal","subject_key":"ios-device:phone-1","schema_version":1,"projection":{}}"#
        let mac = #"{"id":2,"cmd":"put-frontend-projection","frontend":"cmux-next","scope":"personal","subject_key":"windows","schema_version":1,"projection":{}}"#
        let shared = #"{"id":3,"cmd":"put-frontend-projection","frontend":"ios","scope":"shared","subject_key":"ios-device:phone-1","schema_version":1,"projection":{}}"#
        let readShared = #"{"id":4,"cmd":"get-frontend-projection","frontend":"cmux-next","scope":"shared","subject_key":"layout"}"#
        let readMac = #"{"id":5,"cmd":"get-frontend-projection","frontend":"cmux-next","scope":"personal","subject_key":"windows"}"#
        #expect(verdict(own) == .forward)
        #expect(refusal(mac)?["error_code"] as? String == "forbidden")
        #expect(refusal(shared)?["error_code"] as? String == "forbidden")
        #expect(verdict(readShared) == .forward)
        #expect(refusal(readMac)?["error_code"] as? String == "forbidden")
    }

    @Test func refusesMalformedLines() {
        #expect(refusal("not json")?["error_code"] as? String == "bad_request")
        #expect(refusal(#"{"id":1}"#)?["error_code"] as? String == "bad_request")
        #expect(refusal(#"[1,2]"#)?["error_code"] as? String == "bad_request")
    }
}

struct LineSplitterTests {
    @Test func splitsAcrossChunks() throws {
        var splitter = LineSplitter(maximumLineBytes: 16)
        #expect(try splitter.append(Data("ab".utf8)).isEmpty)
        let lines = try splitter.append(Data("c\n\nde\nf".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["abc", "de"])
        #expect(splitter.pendingByteCount == 1)
    }

    @Test func rejectsOverlongLine() {
        var splitter = LineSplitter(maximumLineBytes: 4)
        #expect(throws: LineSplitter.Failure.lineTooLong(limit: 4)) { try splitter.append(Data("12345".utf8)) }
    }
}
