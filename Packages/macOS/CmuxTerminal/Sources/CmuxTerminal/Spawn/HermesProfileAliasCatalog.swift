public import Foundation

/// Caches official Hermes profile aliases for one wrapper directory generation.
///
/// Every terminal surface needs its own command shims, but all surfaces in one
/// app process inspect the same Hermes alias directory. The catalog reduces
/// that shared discovery work to one bounded scan until a directory entry or
/// previously discovered alias file changes.
public actor HermesProfileAliasCatalog {
    private struct FileGeneration: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let modificationDate: Date?
        let permissions: UInt16
        let size: UInt64
    }

    private struct AliasFileGeneration: Equatable, Sendable {
        let commandName: String
        let file: FileGeneration?
    }

    private struct DirectoryGeneration: Equatable, Sendable {
        let directory: FileGeneration?
        let aliasFiles: [AliasFileGeneration]
    }

    private struct Cache: Sendable {
        let generation: DirectoryGeneration
        let reservedCommandNames: Set<String>
        let aliases: [HermesProfileAliasResolver.Alias]
    }

    private let wrapperDirectoryURL: URL
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
        self.wrapperDirectoryURL = directoryURL
        self.fileManager = fileManager
        self.resolver = HermesProfileAliasResolver(
            wrapperDirectoryURL: directoryURL,
            fileManager: fileManager
        )
    }

    /// Returns the aliases for the current directory generation.
    func aliases(excluding reservedCommandNames: Set<String>) -> [HermesProfileAliasResolver.Alias] {
        let generation = directoryGeneration(
            aliasCommandNames: cache?.aliases.map(\.commandName) ?? []
        )
        if let cache,
           cache.generation == generation,
           cache.reservedCommandNames == reservedCommandNames {
            return cache.aliases
        }

        let aliases = resolver.resolve(excluding: reservedCommandNames)
        cache = Cache(
            generation: directoryGeneration(aliasCommandNames: aliases.map(\.commandName)),
            reservedCommandNames: reservedCommandNames,
            aliases: aliases
        )
        return aliases
    }

    private func directoryGeneration(aliasCommandNames: [String]) -> DirectoryGeneration {
        DirectoryGeneration(
            directory: fileGeneration(atPath: wrapperDirectoryURL.path),
            aliasFiles: aliasCommandNames.sorted().map { commandName in
                AliasFileGeneration(
                    commandName: commandName,
                    file: fileGeneration(
                        atPath: wrapperDirectoryURL
                            .appendingPathComponent(commandName, isDirectory: false)
                            .path
                    )
                )
            }
        )
    }

    private func fileGeneration(atPath path: String) -> FileGeneration? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        return FileGeneration(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
    }
}
