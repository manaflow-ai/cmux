public import CmuxHomeCore
public import Foundation

extension ChiefHome {
    /// The mux home of Chief `chief`'s brain under the default Chief's mux
    /// home `muxHome`: `<home>/c/<last 8 of its id, lowercased>` (cmux-tui
    /// chief_brains.rs `brain_home`); nil: the default Chief's `muxHome`.
    public static func brainHome(muxHome: URL, chief: String?) -> URL {
        guard let chief else { return muxHome }
        return muxHome.appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent(String(chief.suffix(8)).lowercased(), isDirectory: true)
    }

    /// The local Chief of a conversation's participants when it is not the
    /// default (cx-327wl): nil with the default Chief (agent_mux) among them,
    /// with no Chief, or with more than one (a group keeps the default rule).
    public static func namedChief(in participants: [Participant]) -> String? {
        let chiefs = participants.filter(\.isChief).map(\.id.rawValue)
        guard chiefs.count == 1, let id = chiefs.first, id != HomeChiefName.muxID else { return nil }
        return id
    }
}
