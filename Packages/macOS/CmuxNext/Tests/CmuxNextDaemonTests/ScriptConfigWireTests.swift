import Foundation
import Testing
@testable import CmuxNextDaemon

/// The config scripts' wire (`script-config-v1`, cmux-tui `server/scripts.rs`).
@Suite struct ScriptConfigWireTests {
    @Test func theChangedEventCarriesItsGeneration() {
        let line = #"{"event":"script-config-changed","generation":7}"#
        guard case .scriptConfigChanged(let generation) = DaemonEvent.decode(name: "script-config-changed", line: Data(line.utf8)) else {
            Issue.record("script-config-changed did not decode")
            return
        }
        #expect(generation == 7)
    }

    @Test func theReportDecodesActionsKeysModesAndRemovals() throws {
        let data = #"""
        {"loaded":true,"generation":2,"dir":"/u/scripts","files":["/u/scripts/init.js"],"applied":true,
         "diagnostics":[{"file":"/u/scripts/b.js","line":3,"column":7,"message":"boom"}],
         "actions":[{"id":"user.hi","name":"hi","title":"Hi","description":null,"palette":true},
                    {"id":"user.key.1","name":"key.1","title":"cmd+k h","description":null,"palette":false}],
         "keys":[{"key":"cmd+k h","command":"user.hi","args":{},"when":null,"mode":null},
                 {"key":"h","command":"focusLeft","args":{},"when":null,"mode":"window"}],
         "modes":[{"name":"window","title":"Window","exclusive":true}],
         "removals":[{"command":"newTab","key":null}]}
        """#
        let report = try JSONDecoder().decode(ScriptConfigReport.self, from: Data(data.utf8))
        #expect(report.actions.map(\.palette) == [true, false])
        #expect(report.keys.map(\.mode) == [nil, "window"])
        #expect(report.modes.first?.exclusive == true)
        #expect(report.removals.first?.key == nil)
        #expect(report.diagnostics.first?.line == 3)
    }

    @Test func actionArgsAndContextKeepTheirKeys() throws {
        let request = ScriptActionRunRequest(action: "user.hi", args: ["someName": .string("x")], context: ["origin": .string("key")])
        let line = try WireCoding.encodeRequest(request, id: 1)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["cmd"] as? String == "script-action-run")
        #expect((object["args"] as? [String: Any])?["someName"] as? String == "x")
        #expect((object["context"] as? [String: Any])?["origin"] as? String == "key")
    }
}
