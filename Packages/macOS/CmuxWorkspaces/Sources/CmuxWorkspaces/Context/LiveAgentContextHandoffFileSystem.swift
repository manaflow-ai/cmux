import Foundation

/// Live local-filesystem implementation used by the handoff verifier.
actor LiveAgentContextHandoffFileSystem: AgentContextHandoffFileSystem {
    private let fileManager: FileManager

    /// Creates the live adapter with its filesystem dependency.
    /// - Parameter fileManager: Filesystem implementation used for metadata.
    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func metadata(for path: URL) async throws -> AgentContextHandoffFileMetadata? {
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: path.path)
        return AgentContextHandoffFileMetadata(
            isRegularFile: (attributes[.type] as? FileAttributeType) == .typeRegular,
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1
        )
    }

    func readData(at path: URL, maximumBytes: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    }
}
