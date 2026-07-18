import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareTerminalVTFrameTests {
    @Test
    func encodesTheCanonicalTerminalVTPayload() throws {
        let surfaceId = "72C552A7-8F75-4DF3-AC47-3750D01D0C18"
        let frame = try WorkspaceShareTerminalVTFrame(
            surfaceId: surfaceId,
            generation: 3,
            stateSeq: 9,
            columns: 120,
            rows: 40,
            kind: .patch,
            data: Data([0x1B, 0x5B, 0x48])
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any]
        )

        #expect(Set(object.keys) == [
            "surfaceId", "generation", "stateSeq", "columns", "rows", "kind", "dataB64",
        ])
        #expect(object["surfaceId"] as? String == surfaceId)
        #expect(object["generation"] as? Int == 3)
        #expect(object["stateSeq"] as? Int == 9)
        #expect(object["columns"] as? Int == 120)
        #expect(object["rows"] as? Int == 40)
        #expect(object["kind"] as? String == "patch")
        #expect(object["dataB64"] as? String == "G1tI")
    }

    @Test
    func rejectsValuesThatCannotBeRelayedSafely() {
        let surfaceId = "72C552A7-8F75-4DF3-AC47-3750D01D0C18"
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidSurfaceId) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: "terminal",
                generation: 1,
                stateSeq: 1,
                columns: 80,
                rows: 24,
                kind: .snapshot,
                data: Data([1])
            )
        }
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidSequence) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: surfaceId,
                generation: 0,
                stateSeq: 1,
                columns: 80,
                rows: 24,
                kind: .snapshot,
                data: Data([1])
            )
        }
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidDimensions) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: surfaceId,
                generation: 1,
                stateSeq: 1,
                columns: WorkspaceShareTerminalVTFrame.maximumDimension + 1,
                rows: 24,
                kind: .snapshot,
                data: Data([1])
            )
        }
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidDimensions) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: surfaceId,
                generation: 1,
                stateSeq: 1,
                columns: 1_000,
                rows: 201,
                kind: .snapshot,
                data: Data([1])
            )
        }
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidDataSize) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: surfaceId,
                generation: 1,
                stateSeq: 1,
                columns: 80,
                rows: 24,
                kind: .snapshot,
                data: Data()
            )
        }
        #expect(throws: WorkspaceShareTerminalVTFrameError.invalidDataSize) {
            try WorkspaceShareTerminalVTFrame(
                surfaceId: surfaceId,
                generation: 1,
                stateSeq: 1,
                columns: 80,
                rows: 24,
                kind: .snapshot,
                data: Data(repeating: 0, count: WorkspaceShareTerminalVTFrame.maximumDataBytes + 1)
            )
        }
    }
}
