import Foundation

/// The New Tab page's saved environments (``AgentPaneEnvironment``), kept on this Mac in
/// `<Application Support>/<bundle id>/environments.json`: read once, written whole (atomically,
/// owner-only, as the folders and machines a user works on are their own). An actor, so the file
/// IO never runs on the main actor. A file that does not parse is read as empty and replaced by
/// the next save.
public actor SavedEnvironments: AgentPaneEnvironmentStoring {
    /// Most environments kept; a save past it is refused.
    static let maximumCount = 200

    enum Failure: Error { case invalid, full, unwritable }

    private let url: URL
    private let now: @Sendable () -> Date
    private var loaded: [AgentPaneEnvironment]?

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// `<Application Support>/<bundle id>/environments.json`.
    public static func forApplication(bundleIdentifier: String?) -> SavedEnvironments {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return SavedEnvironments(url: support.appending(path: bundle).appending(path: "environments.json"))
    }

    private struct Document: Codable {
        var environments: [AgentPaneEnvironment]
    }

    public func list() -> [AgentPaneEnvironment] {
        environments().sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    public func save(_ environment: AgentPaneEnvironment) throws -> AgentPaneEnvironment {
        guard var kept = environment.validated() else { throw Failure.invalid }
        var all = environments()
        kept.id = kept.id ?? UUID().uuidString
        // Always after every kept one, so the list order is the order of the saves.
        let latest = all.compactMap(\.updatedAt).max() ?? 0
        kept.updatedAt = max(Int64((now().timeIntervalSince1970 * 1000).rounded()), latest + 1)
        if let index = all.firstIndex(where: { $0.id == kept.id }) {
            all[index] = kept
        } else {
            guard all.count < Self.maximumCount else { throw Failure.full }
            all.append(kept)
        }
        try write(all)
        return kept
    }

    public func remove(id: String) throws {
        var all = environments()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all.remove(at: index)
        try write(all)
    }

    /// The kept list, read from the file the first time. An entry that no longer validates
    /// (edited by hand) is left out.
    private func environments() -> [AgentPaneEnvironment] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }?.environments ?? []
        let valid = read.compactMap { environment in environment.validated().flatMap { $0.id == nil ? nil : $0 } }
        loaded = valid
        return valid
    }

    private func write(_ all: [AgentPaneEnvironment]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(environments: all))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Owner-only before any byte lands: the temporary file is made 0600, then renamed over.
        let temporary = directory.appending(path: ".environments-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unwritable
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // A plain rename: the new file's own 0600 mode replaces whatever the old one had.
            guard rename(temporary.path, url.path) == 0 else { throw Failure.unwritable }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        loaded = all
    }
}
