import CmuxAgentChat
import Foundation

/// Serializes one artifact stream into an atomic content-cache entry.
actor ChatArtifactContentCacheWriter {
    private let temporaryURL: URL
    private let destinationURL: URL
    private var fileHandle: FileHandle?
    private var memoryData: Data?
    private var validator: ChatArtifactChunkValidator

    init(
        directory: URL,
        key: String,
        expectedSize: Int64,
        retainsMemoryCopy: Bool
    ) throws {
        validator = ChatArtifactChunkValidator(expectedSize: expectedSize)
        let fileManager = FileManager()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        destinationURL = directory.appendingPathComponent(key, isDirectory: false)
        temporaryURL = directory.appendingPathComponent(
            ".\(key).\(UUID().uuidString).partial",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        memoryData = retainsMemoryCopy ? Data() : nil
        if retainsMemoryCopy, expectedSize <= Int64(Int.max) {
            memoryData?.reserveCapacity(Int(expectedSize))
        }
    }

    func append(_ chunk: ChatArtifactChunk) throws {
        try validator.receive(chunk)
        if let fileHandle {
            do {
                try fileHandle.write(contentsOf: chunk.data)
            } catch {
                disablePersistence()
            }
        }
        memoryData?.append(chunk.data)
    }

    func finish() throws -> Data? {
        try validator.finish()
        guard let fileHandle else {
            return memoryData
        }
        do {
            try fileHandle.close()
        } catch {
            disablePersistence()
            return memoryData
        }
        self.fileHandle = nil
        let fileManager = FileManager()
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
        }
        return memoryData
    }

    func discard() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager().removeItem(at: temporaryURL)
    }

    private func disablePersistence() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager().removeItem(at: temporaryURL)
    }
}
