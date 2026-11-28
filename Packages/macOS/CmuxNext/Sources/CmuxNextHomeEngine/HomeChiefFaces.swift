public import CmuxHomeCore
public import CmuxNextHomeModel
public import Foundation

/// The avatar each Chief wears in Home, the sidebar and agent chats (`HomeService.chiefFaces`):
/// its own picture or text, else its `picture` (its upload or picked character), so one Chief's
/// never shows on another; a Chief with neither draws its name's monogram.
extension HomeChiefAvatars {
    /// `own`, with each other Chief in `chiefs` wearing its `picture` when it has one.
    public static func faces(chiefs: Set<String>, own: [String: HomeChiefAvatar], picture: (String) -> URL?) -> [String: HomeChiefAvatar] {
        var faces = own
        for chief in chiefs where faces[chief] == nil {
            if let url = picture(chief) { faces[chief] = .picture(url) }
        }
        return faces
    }

    /// `faces(...)[chief]` for the Chiefs `rows` list (plus the default Chief and `extra`), without
    /// the picture of any other Chief: the sidebar asks once per row, and each picture is a rules call.
    public static func face(of chief: String, rows: [InboxRow], extra: Set<String>, own: [String: HomeChiefAvatar],
                            picture: (String) -> URL?) -> HomeChiefAvatar? {
        if let face = own[chief] { return face }
        let listed = chief == defaultChief || extra.contains(chief)
            || rows.contains { $0.summary.participants.contains { $0.isChief && $0.id.rawValue == chief } }
        return listed ? picture(chief).map { .picture($0) } : nil
    }
}
