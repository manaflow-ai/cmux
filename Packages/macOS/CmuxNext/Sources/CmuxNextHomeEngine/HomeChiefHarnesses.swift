public import CmuxNextDaemon
import CmuxNextHomeModel
public import Foundation

/// The engine each of this Mac's Chiefs runs on, for the Home list's badges
/// (``ChiefBackend/badge(for:)``): the harness its brain saved in its
/// `optchat/engine.json` (`chief.engine.set`), else the engine of its record
/// (`chief.profile.list`), which the brain starts on when engine.json names none
/// (cmux-tui chief_brains.rs `record_engine_env`).
public nonisolated struct HomeChiefHarnesses: Sendable {
    /// The owner's `chief.profile.list` result; nil when it could not be read.
    public typealias List = @Sendable () async -> JSONValue?

    /// The default Chief's mux home (each other Chief's brain home is under it).
    private let muxHome: URL
    private let list: List

    /// - Parameters:
    ///   - muxHome: the default Chief's mux home (`HomeBrainHost.muxHome(tag:)`).
    ///   - list: the owner's Chief records.
    public init(muxHome: URL, list: @escaping List) {
        self.muxHome = muxHome
        self.list = list
    }

    /// The reader over `connection`, the app's connection to this Mac's Chief owner (nil: files only).
    public init(muxHome: URL, connection: DaemonConnection?) {
        self.init(muxHome: muxHome, list: {
            guard let connection else { return nil }
            return try? await ResourceRelayClient(connection: connection).send(
                operation: "chief.profile.list", params: ["machine": .string("current"), "session": .string("current")], idempotencyKey: nil)
        })
    }

    /// Each Chief's brain home under `muxHome` (the default Chief's is `muxHome` itself).
    @MainActor
    static func brainHomes(muxHome: URL, chiefs: Set<String>) -> [String: URL] {
        var homes: [String: URL] = [:]
        for chief in chiefs {
            homes[chief] = ChiefHome.brainHome(muxHome: muxHome, chief: chief == HomeChiefName.muxID ? nil : chief)
        }
        return homes
    }

    /// The effective harness of each Chief in `chiefs` (participant ids) that has one; a
    /// Chief on the brain's own default is left out. Reads files off the main actor.
    public func read(chiefs: Set<String>) async -> [String: String] {
        await readWithDeleted(chiefs: chiefs).harnesses
    }

    /// ``read(chiefs:)`` and, from the same `chief.profile.list`, the ids of this Mac's deleted
    /// Chiefs (nil when the list could not be read), whose conversations Home hides.
    public func readWithDeleted(chiefs: Set<String>) async -> (harnesses: [String: String], deleted: Set<String>?) {
        let listed = await list()
        // brainHome is main-actor isolated: the paths are made here, the files read off it.
        let homes = await Self.brainHomes(muxHome: muxHome, chiefs: chiefs)
        let saved = await Task.detached { () -> [String: String] in
            var saved: [String: String] = [:]
            for (chief, home) in homes {
                saved[chief] = HomeChiefFiles(muxHome: home).engineHarness()
            }
            return saved
        }.value
        return Self.merged(chiefs: chiefs, saved: saved, listed: listed)
    }

    /// Each Chief's harness, the saved one else its record's, and the deleted ids: Rust's
    /// `chief_settings.harnesses` (cmux-home-rules `chief_settings/engine.rs`). Unreadable rules: none.
    static func merged(chiefs: Set<String>, saved: [String: String], listed: JSONValue?) -> (harnesses: [String: String], deleted: Set<String>?) {
        let request = HarnessesRequest(chiefs: chiefs.sorted(), saved: saved, listed: listed ?? .null)
        guard let reply: HarnessesReply = try? HomeRules.call("chief_settings.harnesses", request) else { return ([:], nil) }
        return (reply.harnesses, reply.deleted.map(Set.init))
    }

    private nonisolated struct HarnessesRequest: Encodable {
        var chiefs: [String]
        var saved: [String: String]
        var listed: JSONValue
    }

    private nonisolated struct HarnessesReply: Decodable {
        var harnesses: [String: String]
        var deleted: [String]?
    }
}
