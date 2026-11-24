import Foundation

/// The last agent list read from each Mac. A chooser can draw it immediately while its live
/// request refreshes the rows in place. The files live in this app's Application Support
/// container, so a dev build has its own copy.
@MainActor
public final class AgentCatalogCache {
    public static let shared = AgentCatalogCache()

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.cmux.mobile.agent-catalog", qos: .utility)

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appending(path: "cmux-mobile-agent-catalog", directoryHint: .isDirectory)
        }
    }

    public func load(macID: String) -> AgentCatalog? {
        guard !macID.isEmpty,
              let data = try? Data(contentsOf: file(macID)),
              let catalog = try? JSONDecoder().decode(AgentCatalog.self, from: data),
              !catalog.harnesses.isEmpty else { return nil }
        return catalog
    }

    public func save(_ catalog: AgentCatalog, for macID: String) {
        guard !macID.isEmpty, let data = try? JSONEncoder().encode(catalog) else { return }
        let url = file(macID)
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = url.appendingPathExtension("tmp")
            do {
                try data.write(to: temporary, options: .atomic)
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

    private func file(_ macID: String) -> URL {
        let safe = macID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_"
        }.joined()
        return directory.appending(path: safe + ".json")
    }
}
