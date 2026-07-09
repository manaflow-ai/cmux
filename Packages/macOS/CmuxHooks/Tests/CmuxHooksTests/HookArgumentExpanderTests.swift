import Foundation
import Testing

@testable import CmuxHooks

@Suite
struct HookArgumentExpanderTests {
    @Test
    func expandsEventPaths() {
        let envelope = Data("""
        {
          "name": "workspace.created",
          "payload": {
            "cwd": "/tmp/project",
            "count": 3,
            "ok": true,
            "none": null,
            "object": { "a": 1 },
            "array": [1, "x"]
          }
        }
        """.utf8)
        let expanded = HookArgumentExpander(envelopeJSON: envelope).expand([
            "${event.name}",
            "${event.payload.cwd}",
            "${event.payload.missing}",
            "${event.payload.count}",
            "${event.payload.ok}",
            "${event.payload.none}",
            "${event.payload.object}",
            "prefix-${event.payload.cwd}-${event.name}",
            "${env.HOME}",
        ])
        #expect(expanded[0] == "workspace.created")
        #expect(expanded[1] == "/tmp/project")
        #expect(expanded[2] == "")
        #expect(expanded[3] == "3")
        #expect(expanded[4] == "true")
        #expect(expanded[5] == "")
        #expect(expanded[6] == #"{"a":1}"#)
        #expect(expanded[7] == "prefix-/tmp/project-workspace.created")
        #expect(expanded[8] == "${env.HOME}")
    }
}
