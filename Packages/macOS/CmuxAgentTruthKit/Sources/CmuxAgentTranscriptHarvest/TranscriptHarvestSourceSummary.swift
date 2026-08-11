import Foundation

package struct TranscriptHarvestSourceSummary: Codable, Equatable, Sendable {
    package var filesScanned: Int
    package var linesScanned: Int
    package var unreadableFiles: Int

    package init(filesScanned: Int = 0, linesScanned: Int = 0, unreadableFiles: Int = 0) {
        self.filesScanned = filesScanned
        self.linesScanned = linesScanned
        self.unreadableFiles = unreadableFiles
    }
}
