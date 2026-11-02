import Foundation

/// A GitHub owner's avatar for a project with no icon file of its own (`project.icon`): a repository
/// whose `origin` is on GitHub draws its organization's or user's picture instead of letters.
///
/// Fetched once per owner and kept on disk for a week, so a picker opening does not reach the
/// network each time. A failure (offline, a timeout, no such owner, not an image) is kept for
/// ``retryAfter`` only, so one miss at launch does not leave every repository of that owner on the
/// plain folder until the next launch (Leo 2026-10-28: "why are there so many default icons?").
actor AgentPaneOwnerAvatars {
    static let shared = AgentPaneOwnerAvatars()
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let timeout: TimeInterval = 5
    static let retryAfter: TimeInterval = 60

    typealias Fetch = @Sendable (URL) async -> Data?

    private let folder: URL?
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var known: [String: String] = [:]
    private var failed: [String: Date] = [:]
    private var pending: [String: Task<String?, Never>] = [:]

    init(folder: URL? = AgentPaneOwnerAvatars.defaultFolder, fetch: @escaping Fetch = AgentPaneOwnerAvatars.live,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.fetch = fetch
        self.now = now
    }

    static var defaultFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux/project-avatars", isDirectory: true)
    }

    /// The avatar of `owner` as a data URL, or nil.
    func avatar(for owner: String) async -> String? {
        guard Self.valid(owner) else { return nil }
        let key = owner.lowercased()
        if let known = known[key] { return known }
        if let since = failed[key], now().timeIntervalSince(since) < Self.retryAfter { return nil }
        if let started = pending[key] { return await started.value }
        let task = Task { await self.load(owner: owner, key: key) }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        if let value {
            known[key] = value
            failed[key] = nil
        } else {
            failed[key] = now()
        }
        return value
    }

    private func load(owner: String, key: String) async -> String? {
        let file = folder?.appendingPathComponent(key)
        if let file, let saved = Self.saved(file, now: now()) { return saved }
        guard let url = URL(string: "https://github.com/\(owner).png?size=64"),
              let data = await fetch(url), let src = Self.dataURL(data) else { return nil }
        if let folder, let file {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return src
    }

    /// A file saved less than a week ago, as a data URL.
    private static func saved(_ file: URL, now: Date) -> String? {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) < lifetime,
              let data = try? Data(contentsOf: file) else { return nil }
        return dataURL(data)
    }

    static func dataURL(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= AgentPaneProjectIcon.maximumBytes,
              let type = AgentPaneProjectIcon.imageType(data) else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// A GitHub login: letters, digits and hyphens. Anything else never reaches a URL or a file name.
    static func valid(_ owner: String) -> Bool {
        !owner.isEmpty && owner.utf8.count <= 39 && owner.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }

    static let live: Fetch = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= AgentPaneProjectIcon.maximumBytes else { return nil }
        return data
    }
}
