import Foundation
public import Observation

/// One room (`profiles-v1`, plans/cmux-next/data-model.md; the wire calls
/// rooms profiles).
@Observable @MainActor
public final class ProfileModel: Identifiable {
    public let id: ProfileID
    public internal(set) var name: String
    public internal(set) var color: String?
    public internal(set) var icon: String?
    public internal(set) var theme: String?
    public internal(set) var index: Int
    /// Default browser profile of its workspaces; nil = `default`.
    public internal(set) var browserProfileID: BrowserProfileKey?
    public internal(set) var defaults: ProfileDefaults?
    public internal(set) var defaultSessionID: String?

    init(_ s: ProfileSnapshot) {
        id = s.id
        name = s.name
        color = s.color
        icon = s.icon
        theme = s.theme
        index = s.index
        browserProfileID = s.browserProfileID
        defaults = s.defaults
        defaultSessionID = s.defaultSessionID
    }

    func update(_ s: ProfileSnapshot) {
        if name != s.name { name = s.name }
        if color != s.color { color = s.color }
        if icon != s.icon { icon = s.icon }
        if theme != s.theme { theme = s.theme }
        if index != s.index { index = s.index }
        if browserProfileID != s.browserProfileID { browserProfileID = s.browserProfileID }
        if defaults != s.defaults { defaults = s.defaults }
        if defaultSessionID != s.defaultSessionID { defaultSessionID = s.defaultSessionID }
    }

    public var isDefault: Bool { id == .defaultProfile }
}

extension DaemonStore {
    /// The room ids in order. Never empty: a daemon without personal state
    /// has one implicit `default` room.
    public var profileIDs: [ProfileID] {
        profiles.isEmpty ? [.defaultProfile] : profiles.sorted { $0.index < $1.index }.map(\.id)
    }
}
