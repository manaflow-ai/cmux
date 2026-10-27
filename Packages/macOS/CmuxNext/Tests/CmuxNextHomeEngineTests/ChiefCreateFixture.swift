import CmuxNextIPC
import Foundation

/// `chief.profile.create`'s mutation result as this Mac's Chief owner writes it (cmux-tui
/// chief_registry.rs `wire`, chief_registry_resource.rs), decoded through the generated type.
nonisolated struct ChiefCreateFixture {
    let id: String
    let name: String

    func result() throws -> V2ChiefProfileCreateRequest.Result {
        let record: [String: Any] = [
            "id": id, "display_name": name, "role": "", "personality": "", "instructions": "",
            "avatar": NSNull(), "tools": ["spawn", "tell", "workspaces"], "harnesses": [String](),
            "engine": ["harness": "unii"], "self_edit": ["avatar", "display_name"], "locked": false,
            "is_default": false, "rev": 1, "created_at": "2026-10-26T00:00:00.000Z",
            "updated_at": "2026-10-26T00:00:00.000Z", "brain": ["state": "started"],
        ]
        let reply: [String: Any] = ["value": record, "generation": "g1", "revision": "1", "replayed": false]
        let data = try JSONSerialization.data(withJSONObject: reply)
        return try JSONDecoder().decode(V2ChiefProfileCreateRequest.Result.self, from: data)
    }
}
