import CmuxAgentChat
import Foundation

/// Serializes one streamed artifact into an ordered temporary file.
actor ChatArtifactTemporaryFileWriter {
    let fileURL: URL

    private var fileHandle: FileHandle?
    private var nextOffset: Int64 = 0

    init(
        directory: URL,
        fileExtension: String,
        preferredFilename: String? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL: URL
        if let preferredFilename {
            let itemDirectory = directory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: itemDirectory,
                withIntermediateDirectories: true
            )
            fileURL = itemDirectory.appendingPathComponent(preferredFilename)
        } else {
            var generatedURL = directory.appendingPathComponent(UUID().uuidString)
            if !fileExtension.isEmpty {
                generatedURL.appendPathExtension(fileExtension)
            }
            fileURL = generatedURL
        }
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.fileURL = fileURL
        do {
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func append(_ chunk: ChatArtifactChunk, limit: Int64) throws {
        guard chunk.offset == nextOffset,
              chunk.totalSize <= limit,
              nextOffset <= limit - Int64(chunk.data.count),
              let fileHandle else {
            throw ChatArtifactError.macUnreachable
        }
        try fileHandle.write(contentsOf: chunk.data)
        nextOffset += Int64(chunk.data.count)
    }

    func finish() throws -> URL {
        guard let fileHandle else {
            throw ChatArtifactError.macUnreachable
        }
        try fileHandle.close()
        self.fileHandle = nil
        return fileURL
    }

    func discard() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
