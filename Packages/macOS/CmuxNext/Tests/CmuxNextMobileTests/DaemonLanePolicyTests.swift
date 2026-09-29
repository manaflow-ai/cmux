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
