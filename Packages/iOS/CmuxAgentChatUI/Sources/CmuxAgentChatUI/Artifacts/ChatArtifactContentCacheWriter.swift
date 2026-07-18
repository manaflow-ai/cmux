import CmuxAgentChat
import Foundation

/// Serializes one artifact stream into an atomic content-cache entry.
actor ChatArtifactContentCacheWriter {
    private let expectedSize: Int64
    private let temporaryURL: URL
    private let destinationURL: URL
    private var fileHandle: FileHandle?
    private var memoryData: Data?
    private var nextOffset: Int64 = 0
    private var reachedEOF = false

    init(
        directory: URL,
        key: String,
        expectedSize: Int64,
        retainsMemoryCopy: Bool
    ) throws {
        let fileManager = FileManager()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.expectedSize = expectedSize
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
        guard !reachedEOF,
              chunk.offset == nextOffset,
              chunk.totalSize == expectedSize,
              nextOffset <= expectedSize - Int64(chunk.data.count),
              let fileHandle else {
            throw ChatArtifactError.macUnreachable
        }
        try fileHandle.write(contentsOf: chunk.data)
        memoryData?.append(chunk.data)
        nextOffset += Int64(chunk.data.count)
        reachedEOF = chunk.eof
        if reachedEOF, nextOffset != expectedSize {
            throw ChatArtifactError.macUnreachable
        }
    }

    func finish() throws -> Data? {
        guard reachedEOF, nextOffset == expectedSize, let fileHandle else {
            throw ChatArtifactError.macUnreachable
        }
        try fileHandle.close()
        self.fileHandle = nil
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return memoryData
    }

    func discard() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager().removeItem(at: temporaryURL)
    }
}
