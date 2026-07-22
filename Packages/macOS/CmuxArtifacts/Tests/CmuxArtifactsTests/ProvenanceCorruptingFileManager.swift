import Foundation

/// Injects a concurrent provenance corruption immediately after the artifact move.
final class ProvenanceCorruptingFileManager: FileManager, @unchecked Sendable {
    private let metadataURL: URL

    init(metadataURL: URL) {
        self.metadataURL = metadataURL
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{corrupt".utf8).write(to: metadataURL)
    }
}
