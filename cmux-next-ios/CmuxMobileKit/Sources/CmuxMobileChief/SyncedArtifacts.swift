import CmuxMobileArtifacts
import Foundation
import Observation

/// The account's synced artifacts and memories (the Mac's Artifacts page,
/// `ArtifactsPageProvider`): the tree, a file's preview and the history, read only, from the
/// platform's `/v1/artifacts` reads with this phone's own token.
public struct SyncedArtifacts: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var name: String
        public var path: String
        public var isFolder: Bool
        public var size: Int?
        public var id: String { path }
    }

    public struct Commit: Identifiable, Hashable, Sendable {
        public var sha: String
        public var message: String
        public var author: String
        public var time: Date
        /// Who saved it, when the saver said: the agent session, machine and harness.
        public var session: String?
        public var machine: String?
        public var harness: String?
        public var paths: [String]
        public var id: String { sha }
        public var shortSHA: String { String(sha.prefix(7)) }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        case signedOut, notFound, unreachable, failed

        public var description: String {
            switch self {
            case .signedOut: String(localized: "Sign in to cmux to see your artifacts.")
            case .notFound: String(localized: "Nothing has been saved here yet.")
            case .unreachable: String(localized: "Artifacts could not be reached. Check that you are signed in and online, then try again.")
            case .failed: String(localized: "Artifacts could not be loaded. Try again.")
            }
        }
    }

    /// A file larger than this is not previewed (the Mac's limit).
    public static let previewLimit = 4 * 1024 * 1024

    let account: AccountCloud

    public init(account: AccountCloud) {
        self.account = account
    }

    /// The immediate children of `path` (the root when empty), folders first, then by name.
    public func tree(_ path: String, ref: String? = nil) async throws -> [Entry] {
        let data = try await get("/v1/artifacts/tree", query: query(path: path, ref: ref))
        return Self.entries(data)
    }

    /// The history of `path` (everything when empty), newest first.
    public func history(_ path: String, ref: String? = nil, limit: Int = 50) async throws -> [Commit] {
        var items = query(path: path, ref: ref)
        items.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))))
        return Self.commits(try await get("/v1/artifacts/history", query: items))
    }

    /// One file's bytes at `ref` (the newest when nil).
    public func file(_ path: String, ref: String? = nil) async throws -> Data {
        guard !path.isEmpty else { throw Failure.notFound }
        var items = [URLQueryItem(name: "path", value: path)]
        if let ref { items.insert(URLQueryItem(name: "ref", value: ref), at: 0) }
        let data = try await get("/v1/artifacts/file", query: items)
        guard data.count <= Self.previewLimit else {
            throw ArtifactUnavailable(String(localized: "This file is too large to preview on iPhone."))
        }
        return data
    }

    private func query(path: String, ref: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let ref { items.append(URLQueryItem(name: "ref", value: ref)) }
        if !path.isEmpty { items.append(URLQueryItem(name: "path", value: path)) }
        return items
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        let reply: AccountCloud.PlatformReply
        do { reply = try await account.platformGet(path, query: query) } catch is CancellationError {
            throw CancellationError()
        } catch let AccountCloud.Failure.refused(status, _, _) where status == 401 {
            throw Failure.signedOut
        } catch {
            throw Failure.unreachable
        }
        switch reply.status {
        case 200..<300: return reply.body
        case 401, 403: throw Failure.signedOut
        case 404: throw Failure.notFound
        default: throw Failure.failed
        }
    }

    static func entries(_ data: Data) -> [Entry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["entries"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> Entry? in
            guard let name = item["name"] as? String, let path = item["path"] as? String else { return nil }
            return Entry(name: name, path: path, isFolder: item["type"] as? String == "tree", size: (item["size"] as? NSNumber)?.intValue)
        }
        .sorted { ($0.isFolder ? 0 : 1, $0.name.localizedLowercase) < ($1.isFolder ? 0 : 1, $1.name.localizedLowercase) }
    }

    static func commits(_ data: Data) -> [Commit] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["commits"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let sha = item["sha"] as? String else { return nil }
            let trailers = item["trailers"] as? [String: Any] ?? [:]
            let time = (item["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            return Commit(sha: sha, message: (item["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          author: item["authorName"] as? String ?? "", time: time,
                          session: trailers["session"] as? String, machine: trailers["machine"] as? String,
                          harness: trailers["harness"] as? String, paths: item["paths"] as? [String] ?? [])
        }
    }
}

/// A synced file as the shared preview reads it: the reference is its path, `ref` the commit
/// (nil: the newest).
public struct SyncedArtifactSource: ArtifactSource {
    let artifacts: SyncedArtifacts
    let ref: String?

    public init(artifacts: SyncedArtifacts, ref: String?) {
        self.artifacts = artifacts
        self.ref = ref
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        let data: Data
        do { data = try await artifacts.file(artifact.reference, ref: ref) } catch let failure as SyncedArtifacts.Failure {
            throw ArtifactUnavailable(failure.description)
        }
        return try LinkFileArtifactSource.content(for: artifact, data: data)
    }

    /// The preview's artifact for a synced path.
    public static func artifact(_ path: String) -> TerminalArtifact {
        TerminalArtifact(reference: path, kind: TerminalArtifact.kind(forExtension: (path as NSString).pathExtension) ?? .text)
    }
}

/// One folder of the synced tree, or one history, as a page loads it.
@MainActor
@Observable
public final class SyncedArtifactsPage<Item: Sendable> {
    public enum Phase {
        case loading
        case loaded([Item])
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    @ObservationIgnored private let read: @MainActor () async throws -> [Item]

    public init(read: @escaping @MainActor () async throws -> [Item]) {
        self.read = read
    }

    public func load() async {
        do {
            phase = .loaded(try await read())
        } catch is CancellationError {
            return
        } catch let failure as SyncedArtifacts.Failure {
            phase = .failed(failure.description)
        } catch {
            phase = .failed(SyncedArtifacts.Failure.failed.description)
        }
    }
}
