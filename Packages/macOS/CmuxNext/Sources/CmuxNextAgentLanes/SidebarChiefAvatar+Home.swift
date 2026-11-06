public import CmuxNextHome
public import CmuxNextSidebar

extension SidebarChiefAvatar {
    /// The same face Home resolved for this Chief; the unchanged default is its CH monogram.
    public init(home: HomeChiefAvatar?) {
        switch HomeChiefAvatar.resolved(home) {
        case .picture(let url): self = .picture(url)
        case .text(let text): self = .text(text)
        }
    }
}
