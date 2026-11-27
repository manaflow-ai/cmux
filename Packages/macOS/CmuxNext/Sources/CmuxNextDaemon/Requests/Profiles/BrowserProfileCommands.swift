import Foundation

// Browser profile records (`browser-profiles-v1`, home session only;
// plans/cmux-next/data-model.md section 5). Every change emits
// `personal-changed`. The requests are generated from the schema.

public struct BrowserProfileResult: Decodable, Sendable, Equatable {
    public var browserProfile: BrowserProfileSnapshot
    public var changed: Bool
    enum CodingKeys: String, CodingKey {
        case changed
        case browserProfile = "browser_profile"
    }
}
