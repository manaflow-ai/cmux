public import CmuxNextHome
public import CmuxNextSidebar

extension SidebarChiefAvatar {
    /// The face the Chief's profile chose, as Home resolved it. A Chief with none draws no mark on
    /// the row: its default monogram ("CH") reads as noise beside a workspace title.
    public init?(home: HomeChiefAvatar?) {
        switch home {
        case .picture(let url): self = .picture(url)
        case .text(let text): self = .text(text)
        case nil: return nil
        }
    }
}
