import Foundation
import Testing
@testable import CmuxSettingsUI

@Suite("LocalTmuxSessionListDecoder")
struct LocalTmuxSessionListDecoderTests {
    /// Decodes managed, unmanaged, live, and stale rows into stable identities.
    @Test func decodesAuthoritativeRows() throws {
        let managedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let payload: [String: Any] = [
            "sessions": [
                [
                    "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "session_name": "stale",
                    "cwd": "/tmp/stale",
                    "managed": true,
                    "live": false,
                ],
                [
                    "id": managedID.uuidString,
                    "session_name": "work",
                    "cwd": "/tmp/work",
                    "clients": 2,
                    "managed": true,
                    "live": true,
                ],
                [
                    "id": NSNull(),
                    "session_name": "manual",
                    "clients": 0,
                    "managed": false,
                    "live": true,
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let sessions = try LocalTmuxSessionListDecoder().decode(data)

        #expect(sessions.map(\.name) == ["manual", "work", "stale"])
        #expect(sessions[0].id == "tmux:manual")
        #expect(sessions[0].logicalID == nil)
        #expect(sessions[1].logicalID == managedID)
        #expect(sessions[1].clientCount == 2)
        #expect(sessions[2].clientCount == 0)
    }

    /// Rejects missing lifecycle fields, inconsistent identity, and bad clients.
    @Test func rejectsMalformedRows() throws {
        let rows: [[String: Any]] = [
            [
                "id": NSNull(),
                "session_name": "missing-live",
                "managed": false,
            ],
            [
                "id": "not-a-uuid",
                "session_name": "managed-bad-id",
                "managed": true,
                "live": true,
            ],
            [
                "id": UUID().uuidString,
                "session_name": "unmanaged-with-id",
                "managed": false,
                "live": true,
            ],
            [
                "id": NSNull(),
                "session_name": "bad-clients",
                "clients": "two",
                "managed": false,
                "live": true,
            ],
        ]

        for row in rows {
            let data = try JSONSerialization.data(withJSONObject: ["sessions": [row]])
            #expect(throws: LocalTmuxSessionListDecoder.Failure.self) {
                _ = try LocalTmuxSessionListDecoder().decode(data)
            }
        }
    }
    @Test func publicConstructionKeepsDisplayAndAttachmentIdentityTogether() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let managed = LocalTmuxSessionSummary(
            selector: .managed(id: id, name: "work"), cwd: nil, clientCount: 0, isLive: true
        )
        #expect(managed.id == id.uuidString)
        #expect(managed.logicalID == id)
        #expect(managed.isManaged)
        #expect(managed.name == "work")
        let unmanaged = LocalTmuxSessionSummary(
            selector: .unmanaged(name: "manual"), cwd: nil, clientCount: 0, isLive: true
        )
        #expect(unmanaged.id == "tmux:manual")
        #expect(unmanaged.logicalID == nil)
        #expect(!unmanaged.isManaged)
        #expect(unmanaged.name == "manual")
    }

}
