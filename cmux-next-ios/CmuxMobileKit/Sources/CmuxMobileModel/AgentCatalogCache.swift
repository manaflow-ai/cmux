import Foundation

/// The last agent list read from each Mac. A chooser can draw it immediately while its live
/// request refreshes the rows in place. The files live in this app's Application Support
/// container, so a dev build has its own copy.
@MainActor
public final class AgentCatalogCache {
    public static let shared = AgentCatalogCache()

    private let directory: URL
    private let accountID: @MainActor () -> String?
    private let queue = DispatchQueue(label: "dev.cmux.mobile.agent-catalog", qos: .utility)

    public init(directory: URL? = nil,
                accountID: @escaping @MainActor () -> String? = { AccountPreferences.standard.currentUserID }) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appending(path: "cmux-mobile-agent-catalog", directoryHint: .isDirectory)
        }
        self.accountID = accountID
    }

    public func load(macID: String) -> AgentCatalog? {
        guard !macID.isEmpty,
              let data = file(macID).flatMap({ try? Data(contentsOf: $0) }),
              let catalog = try? JSONDecoder().decode(AgentCatalog.self, from: data) else { return nil }
        return catalog
    }

    public func save(_ catalog: AgentCatalog, for macID: String) {
        guard !macID.isEmpty, let data = try? JSONEncoder().encode(catalog), let url = file(macID) else { return }
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let temporary = url.appendingPathExtension("tmp")
            do {
                try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }

    public func removeAll() {
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for pending writes in tests. Production callers never need to wait for this cache.
    func flush() {
        queue.sync {}
    }

    private func file(_ macID: String) -> URL? {
        guard let accountID = accountID(), !accountID.isEmpty else { return nil }
        return directory
            .appending(path: "account-\(Self.safe(accountID))", directoryHint: .isDirectory)
            .appending(path: Self.safe(macID) + ".json")
    }

    private static func safe(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_"
        }.joined()
    }
}
