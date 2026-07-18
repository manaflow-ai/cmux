import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareTerminalInputTests {
    private let surfaceId = "72C552A7-8F75-4DF3-AC47-3750D01D0C18"

    @Test
    func encodesTheExactSurfaceRevisionAndInputKind() throws {
        let input = try WorkspaceShareTerminalInput(
            surfaceId: surfaceId,
            layoutRevision: 17,
            kind: .key,
            data: "ctrl-c"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any]
        )

        #expect(Set(object.keys) == ["surfaceId", "layoutRevision", "kind", "data"])
        #expect(object["surfaceId"] as? String == surfaceId)
        #expect(object["layoutRevision"] as? Int == 17)
        #expect(object["kind"] as? String == "key")
        #expect(object["data"] as? String == "ctrl-c")
    }

    @Test
    func decodesBoundedTextAndEverySupportedKeyFamily() throws {
        let text = try decode(kind: "text", data: "こんにちは🙂")
        #expect(text.kind == .text)
        for key in [
            "enter", "backspace", "tab", "shift-tab", "escape", "up", "down", "left", "right",
            "home", "end", "delete", "ctrl-a", "ctrl-z", "ctrl-\\",
        ] {
            #expect(try decode(kind: "key", data: key).data == key)
        }
    }

    @Test
    func rejectsControlsOversizedTextUnknownKeysAndInvalidTargets() {
        #expect(throws: WorkspaceShareTerminalInputError.invalidText) {
            try WorkspaceShareTerminalInput(
                surfaceId: surfaceId,
                layoutRevision: 1,
                kind: .text,
                data: "echo\n"
            )
        }
        #expect(throws: WorkspaceShareTerminalInputError.invalidText) {
            try WorkspaceShareTerminalInput(
                surfaceId: surfaceId,
                layoutRevision: 1,
                kind: .text,
                data: String(repeating: "🙂", count: WorkspaceShareTerminalInput.maximumTextBytes / 4 + 1)
            )
        }
        #expect(throws: WorkspaceShareTerminalInputError.invalidKey) {
            try WorkspaceShareTerminalInput(
                surfaceId: surfaceId,
                layoutRevision: 1,
                kind: .key,
                data: "command-enter"
            )
        }
        #expect(throws: WorkspaceShareTerminalInputError.invalidSurfaceId) {
            try WorkspaceShareTerminalInput(
                surfaceId: "terminal",
                layoutRevision: 1,
                kind: .key,
                data: "enter"
            )
        }
        #expect(throws: WorkspaceShareTerminalInputError.invalidLayoutRevision) {
            try WorkspaceShareTerminalInput(
                surfaceId: surfaceId,
                layoutRevision: WorkspaceShareTerminalInput.maximumSafeLayoutRevision + 1,
                kind: .key,
                data: "enter"
            )
        }
    }

    private func decode(kind: String, data: String) throws -> WorkspaceShareTerminalInput {
        let object: [String: Any] = [
            "surfaceId": surfaceId,
            "layoutRevision": 3,
            "kind": kind,
            "data": data,
        ]
        return try JSONDecoder().decode(
            WorkspaceShareTerminalInput.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
