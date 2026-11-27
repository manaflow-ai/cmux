import CmuxUpdater
public import Foundation

/// The channels view's data (Settings > Updates): every ring's recent builds with their canary
/// verdicts and pulls, which one this Mac runs, and which it kept for rollback. Read on demand,
/// from the files the feed already publishes next to its appcast; nothing polls.
extension UpdaterService {
    /// The tracks, one per ring, slowest first. Offline, the verified notes cache answers and
    /// verdicts and pulls read as unknown.
    public func channelTracks(limit: Int = 10) async -> [ChannelTrack] {
        let store = changelogNotes
        let index = await store?.index() ?? []
        let folder = store.map { Self.channelFolder(notesBase: $0.notesBase) }
        let limit = max(0, limit)
        let recent = Array(index.prefix(limit))
        let kept = await Task.detached { [keptVersions] in Set(keptVersions.list().map(\.build)) }.value
        async let verdicts = Self.verdicts(for: recent.map(\.build), in: folder)
        async let pulled = Self.pulled(in: folder)
        async let feed = feedItems()
        return ChannelTrack.tracks(index: recent, verdicts: await verdicts, pulled: await pulled,
                                   installedBuild: identity.build, keptBuilds: kept, followed: ring, limit: limit,
                                   feedItems: await feed)
    }

    /// Every item of this app's feed the fastest ring sees; none offline or for a build that
    /// follows no feed.
    func feedItems() async -> [AppcastItem] {
        guard switchesBuilds else { return [] }
        let allowed = identity.feed().channel.allowedSparkleChannels(ring: .dev)
        var feedIdentity = identity
        if let testFeedURL { feedIdentity.infoFeedURL = testFeedURL }
        return (try? await prober.offered(feedIdentity, allowedChannels: allowed)) ?? []
    }

    /// Where the cmux NEXT feed keeps `verdicts/` and `pulled.json`: beside its appcast
    /// (`/nightly-next/next/`). A DEV build's notes and the legacy NIGHTLY feed live one folder up
    /// (`/nightly-next/`) under the same build numbers, so they read the cmux NEXT folder.
    nonisolated static func channelFolder(notesBase: URL) -> URL {
        let folder = notesBase.deletingLastPathComponent()
        return folder.path.hasSuffix("/nightly-next") || folder.path.hasSuffix("/nightly-next/")
            ? folder.appending(path: "next", directoryHint: .isDirectory) : folder
    }

    /// Each build's `verdicts/<build>.json` verdict (pass, fail, skipped), read in parallel.
    nonisolated static func verdicts(for builds: [String], in folder: URL?,
                                     fetch: @escaping @Sendable (URL) async -> Data? = PulledBuildWatch.download) async -> [String: String] {
        guard let folder else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { group in
            for build in builds where ReleaseNotesStore.isSafeName(build) {
                group.addTask {
                    let data = await fetch(folder.appending(path: "verdicts/\(build).json"))
                    let doc = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    return (build, doc?["verdict"] as? String)
                }
            }
            var result: [String: String] = [:]
            for await (build, verdict) in group { result[build] = verdict }
            return result
        }
    }

    /// The feed's `pulled.json`, or none.
    nonisolated static func pulled(in folder: URL?,
                                   fetch: @Sendable (URL) async -> Data? = PulledBuildWatch.download) async -> [PulledBuild] {
        guard let folder, let data = await fetch(folder.appending(path: "pulled.json")) else { return [] }
        return PulledBuild.decode(data)
    }
}
