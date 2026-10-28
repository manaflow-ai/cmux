public import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextIPC
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
    /// The lanes the brains' engine.json files are read on.
    private let lanes: any MayBlockRunner

    /// - Parameters:
    ///   - muxHome: the default Chief's mux home (`HomeBrainHost.muxHome(tag:)`).
    ///   - files: the lanes the engine files are read on (the app's `work`).
    ///   - list: the owner's Chief records.
    public init(muxHome: URL, files: any MayBlockRunner, list: @escaping List) {
        self.muxHome = muxHome
        self.lanes = files
        self.list = list
    }

    /// The reader over `connection`, the app's connection to this Mac's Chief owner (nil: files only).
    public init(muxHome: URL, files: any MayBlockRunner, connection: DaemonConnection?) {
        self.init(muxHome: muxHome, files: files, list: {
            guard let connection else { return nil }
            return try? await ResourceOperationClient(connection: connection).read(V2ChiefProfileListRequest(),
                                                                                   as: JSONValue.self)
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
    /// Chief on the brain's own default is left out. Reads files on the files lane (`.userVisible`: the badges show).
    public func read(chiefs: Set<String>) async -> [String: String] {
        await readWithDeleted(chiefs: chiefs).harnesses
    }

    /// ``read(chiefs:)`` and, from the same `chief.profile.list`, the ids of this Mac's deleted
    /// Chiefs (nil when the list could not be read), whose conversations Home hides.
    public func readWithDeleted(chiefs: Set<String>) async -> (harnesses: [String: String], deleted: Set<String>?) {
        let listed = await list()
        let records = Self.recordHarnesses(listed)
        // brainHome is main-actor isolated: the paths are made here, the files read off it.
        let homes = await Self.brainHomes(muxHome: muxHome, chiefs: chiefs)
        // Dropped (cancelled, or the app is quitting): the records' engines show.
        let saved = (try? await lanes.runFiles(.userVisible) { () -> [String: String] in
            var saved: [String: String] = [:]
            for (chief, home) in homes {
                saved[chief] = HomeChiefFiles(muxHome: home).engineHarness()
            }
            return saved
        }) ?? [:]
        var harnesses: [String: String] = [:]
        for chief in chiefs {
            if let harness = saved[chief] ?? records[chief] { harnesses[chief] = harness }
        }
        return (harnesses, Self.deletedIDs(listed))
    }

    /// The deleted Chiefs' ids of a `chief.profile.list` result (`deleted`); nil when there is no
    /// result or the owner does not list them (an older daemon), so the ids known stay.
    static func deletedIDs(_ listed: JSONValue?) -> Set<String>? {
        guard case .object(let reply)? = listed else { return nil }
        var object = reply
        if case .object(let value)? = reply["value"] { object = value }
        guard case .array(let ids)? = object["deleted"] else { return nil }
        return Set(ids.compactMap { if case .string(let id) = $0 { id } else { nil } })
    }

    /// Each record's `engine.harness` by Chief id, from a `chief.profile.list` result.
    static func recordHarnesses(_ listed: JSONValue?) -> [String: String] {
        guard case .object(let reply)? = listed else { return [:] }
        var object = reply
        if case .object(let value)? = reply["value"] { object = value }
        guard case .array(let chiefs)? = object["chiefs"] else { return [:] }
        var harnesses: [String: String] = [:]
        for case .object(let record) in chiefs {
            guard case .string(let id)? = record["id"], case .object(let engine)? = record["engine"],
                  case .string(let harness)? = engine["harness"], !harness.isEmpty else { continue }
            harnesses[id] = harness
        }
        return harnesses
    }
}
