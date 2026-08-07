public import Foundation

/// Caches official Hermes profile aliases for one wrapper directory generation.
///
/// Every terminal surface needs its own command shims, but all surfaces in one
/// app process inspect the same Hermes alias directory. The catalog reduces
/// that shared discovery work to one bounded scan until the directory changes.
public actor HermesProfileAliasCatalog {
    private struct DirectoryGeneration: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let modificationDate: Date?
        let permissions: UInt16
        let size: UInt64
    }

    private struct Cache: Sendable {
        let generation: DirectoryGeneration?
        let reservedCommandNames: Set<String>
        let aliases: [HermesProfileAliasResolver.Alias]
    }

    private let wrapperDirectoryPath: String
    private let fileManager: FileManager
    private let resolver: HermesProfileAliasResolver
    private var cache: Cache?

    /// Creates a catalog for the directory containing Hermes profile aliases.
    ///
    /// - Parameters:
    ///   - wrapperDirectoryURL: The directory populated by Hermes's `profile alias` command.
    ///   - fileManager: The filesystem implementation used to read alias wrappers.
    public init(
        wrapperDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        let directoryURL = wrapperDirectoryURL.standardizedFileURL
        self.wrapperDirectoryPath = directoryURL.path
        self.fileManager = fileManager
        self.resolver = HermesProfileAliasResolver(
            wrapperDirectoryURL: directoryURL,
            fileManager: fileManager
        )
    }

    /// Returns the aliases for the current directory generation.
    func aliases(excluding reservedCommandNames: Set<String>) -> [HermesProfileAliasResolver.Alias] {
        let generation = directoryGeneration()
        if let cache,
           cache.generation == generation,
           cache.reservedCommandNames == reservedCommandNames {
            return cache.aliases
        }

        let aliases = resolver.resolve(excluding: reservedCommandNames)
        cache = Cache(
            generation: generation,
            reservedCommandNames: reservedCommandNames,
            aliases: aliases
        )
        return aliases
    }

    private func directoryGeneration() -> DirectoryGeneration? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: wrapperDirectoryPath) else {
            return nil
        }
        return DirectoryGeneration(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
    }
}
