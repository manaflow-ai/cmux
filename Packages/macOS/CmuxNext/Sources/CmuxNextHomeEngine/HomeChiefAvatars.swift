public import CmuxNextHome
public import Foundation

/// Each of this Mac's Chiefs' own avatar for the Home list, keyed by
/// participant id: read from that Chief's own brain home
/// (``ChiefHome/brainHome(muxHome:chief:)``, its `optchat/profile.json`),
/// never from the default Chief's. A Chief that sets none is left out, so the
/// list draws the default for it alone.
public nonisolated struct HomeChiefAvatars: Sendable {
    /// The default Chief's mux home (each other Chief's brain home is under it).
    private let muxHome: URL

    /// - Parameter muxHome: the default Chief's mux home (`HomeBrainHost.muxHome(tag:)`).
    public init(muxHome: URL) {
        self.muxHome = muxHome
    }

    /// The avatar of each Chief in `chiefs` (participant ids) that sets one.
    /// Reads the profile files off the main actor.
    public func read(chiefs: Set<String>) async -> [String: HomeChiefAvatar] {
        let muxHome = muxHome
        return await Task.detached { () -> [String: HomeChiefAvatar] in
            var avatars: [String: HomeChiefAvatar] = [:]
            for chief in chiefs {
                let home = ChiefHome.brainHome(muxHome: muxHome, chief: chief == HomeChiefName.muxID ? nil : chief)
                avatars[chief] = HomeChiefFiles(muxHome: home).tileAvatar()
            }
            return avatars
        }.value
    }
}
