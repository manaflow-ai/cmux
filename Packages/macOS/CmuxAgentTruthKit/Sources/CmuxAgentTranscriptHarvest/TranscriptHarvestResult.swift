import Foundation

package struct TranscriptHarvestResult: Codable, Equatable, Sendable {
    package var rows: [TranscriptShapeRow]
    package var summaries: [TranscriptHarvestSource: TranscriptHarvestSourceSummary]
    package var decoderGapRows: [TranscriptShapeRow]

    package init(
        rows: [TranscriptShapeRow],
        summaries: [TranscriptHarvestSource: TranscriptHarvestSourceSummary],
        decoderGapRows: [TranscriptShapeRow]
    ) {
        self.rows = rows
        self.summaries = summaries
        self.decoderGapRows = decoderGapRows
    }

    package func outputRows() -> [TranscriptShapeRow] {
        var output = rows
        for source in TranscriptHarvestSource.allCases {
            let summary = summaries[source] ?? TranscriptHarvestSourceSummary()
            output.append(TranscriptShapeRow(source: source, dimension: "summary", value: "files_scanned", count: summary.filesScanned))
            output.append(TranscriptShapeRow(source: source, dimension: "summary", value: "lines_scanned", count: summary.linesScanned))
            output.append(TranscriptShapeRow(source: source, dimension: "summary", value: "unreadable_files", count: summary.unreadableFiles))
        }
        output.append(contentsOf: decoderGapRows)
        return output
    }
}
