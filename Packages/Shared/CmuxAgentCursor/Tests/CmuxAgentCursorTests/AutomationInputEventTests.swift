import Foundation
import Testing
@testable import CmuxAgentCursor

/// Vendored from manaflow-ai/cmux@1df71bac4a3:schemas/automation-input/vectors.json.
private func vectors() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "automation-input-vectors", withExtension: "json", subdirectory: "Resources"))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func data(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

@Suite struct AutomationInputEventTests {
    @Test func acceptsEveryValidVector() throws {
        let valid = try #require(try vectors()["valid"] as? [[String: Any]])
        #expect(valid.count >= 7)
        for event in valid {
            #expect(throws: Never.self) { _ = try AutomationInputEvent.decode(try data(event)) }
        }
    }

    @Test func rejectsEveryInvalidVector() throws {
        let invalid = try #require(try vectors()["invalid"] as? [[String: Any]])
        #expect(invalid.count >= 10)
        for entry in invalid {
            let why = entry["why"] as? String ?? "?"
            let event = try #require(entry["event"])
            #expect(throws: AutomationInputEventError.self, "\(why)") {
                _ = try AutomationInputEvent.decode(try data(event))
            }
        }
    }

    @Test func decodesFieldsAndZoom() throws {
        let json = #"{"v":1,"session_id":"s3","target_id":"tab_9","seq":4,"kind":"double_click","space":"viewport","point":{"x":40,"y":12},"rect":{"x":30,"y":5,"w":20,"h":14},"zoom":1.25,"t_ms":3000}"#
        let event = try AutomationInputEvent.decode(Data(json.utf8))
        #expect(event.sessionID == "s3")
        #expect(event.targetID == "tab_9")
        #expect(event.seq == 4)
        #expect(event.kind == .doubleClick)
        #expect(event.space == .viewport)
        #expect(event.point == .init(x: 40, y: 12))
        #expect(event.rect == .init(x: 30, y: 5, w: 20, h: 14))
        #expect(event.zoom == 1.25)
        #expect(event.tMs == 3000)
    }
}
