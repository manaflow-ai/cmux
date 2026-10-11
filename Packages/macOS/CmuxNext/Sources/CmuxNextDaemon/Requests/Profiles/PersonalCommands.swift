import Foundation

// Personal state commands (`profiles-v1`, home session only;
// plans/cmux-next/data-model.md 3.3). Each emits `personal-changed`.

public struct ListPersonalRequest: DaemonRequest {
    public typealias Response = PersonalState
    public static let command = "list-personal"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public init() {}
}

public struct SetProfileFollowsRequest: DaemonRequest {
    public typealias Response = ProfileResult
    public static let command = "set-profile-follows"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var profile: ProfileID
    public var sessionIDs: [String]
    public init(profile: ProfileID, sessionIDs: [String]) {
        self.profile = profile
        self.sessionIDs = sessionIDs
    }

    enum CodingKeys: String, CodingKey {
        case profile
        case sessionIDs = "session_ids"
    }
}
