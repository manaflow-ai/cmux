public import CmuxHomeCore

extension HomeChiefAvatar {
    /// The avatar each Chief in `participants` wears beside a group's bubbles, by participant id:
    /// its own (`own`, the Home list's `chiefAvatars`), else `fallback`, as its Home row draws it
    /// (`HomeSidebarModel`). People are not listed: they keep their initials.
    public nonisolated static func bubbleAvatars(for participants: [Participant], own: [String: HomeChiefAvatar],
                                     fallback: HomeChiefAvatar) -> [String: HomeChiefAvatar] {
        var out: [String: HomeChiefAvatar] = [:]
        for chief in participants where chief.isChief {
            out[chief.id.rawValue] = own[chief.id.rawValue] ?? fallback
        }
        return out
    }
}
