public import CmuxHomeCore
public import Foundation

extension ChiefHome {
    /// The mux home of Chief `chief`'s brain under the default Chief's mux
    /// home `muxHome`: `<home>/c/<last 8 of its id, lowercased>` (cmux-tui
    /// chief_brains.rs `brain_home`, Rust `chief_home.brain_home`); nil: the default Chief's `muxHome`.
    nonisolated public static func brainHome(muxHome: URL, chief: String?) -> URL {
        guard let chief else { return muxHome }
        struct Request: Encodable { let muxHome: String; let chief: String? }
        struct Reply: Decodable { let brainHome: String }
        guard let reply: Reply = try? ChiefHomeRules().call("brain_home", Request(muxHome: muxHome.path, chief: chief)) else {
            return muxHome.appendingPathComponent("c", isDirectory: true)
                .appendingPathComponent(String(chief.suffix(8)).lowercased(), isDirectory: true)
        }
        return URL(fileURLWithPath: reply.brainHome, isDirectory: true)
    }

    /// The local Chief of a conversation's participants when it is not the
    /// default (cx-327wl): nil with the default Chief (agent_mux) among them,
    /// with no Chief, or with more than one (a group keeps the default rule; Rust `chief_home.named_chief`).
    public static func namedChief(in participants: [Participant]) -> String? {
        struct Member: Encodable { let id: String; let isChief: Bool }
        struct Request: Encodable { let participants: [Member] }
        struct Reply: Decodable { let chief: String? }
        let request = Request(participants: participants.map { Member(id: $0.id.rawValue, isChief: $0.isChief) })
        return ((try? ChiefHomeRules().call("named_chief", request)) as Reply?)?.chief
    }
}
