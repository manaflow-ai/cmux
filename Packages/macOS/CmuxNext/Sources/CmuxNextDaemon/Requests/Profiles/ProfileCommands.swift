import Foundation

// Profiles (`profiles-v1`, plans/cmux-next/data-model.md section 3). Profile
// edits emit `tree-changed`; a workspace changing profile emits
// `workspace-moved` with the entity carrying `profile`.

public struct ProfileResult: Decodable, Sendable, Equatable {
    public var profile: ProfileSnapshot
    public var changed: Bool
}
