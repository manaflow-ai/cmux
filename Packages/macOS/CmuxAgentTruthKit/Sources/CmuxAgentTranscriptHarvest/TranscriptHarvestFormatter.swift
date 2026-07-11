import Foundation

package struct TranscriptHarvestFormatter {
    package init() {
    }

    package func tsv(_ result: TranscriptHarvestResult) -> String {
        var lines = ["source\tdimension\tvalue\tcount\tmarker"]
        lines.append(contentsOf: result.outputRows().map { row in
            [
                row.source.rawValue,
                row.dimension,
                row.value,
                String(row.count),
                row.marker ?? "",
            ].joined(separator: "\t")
        })
        return lines.joined(separator: "\n")
    }

    package func json(_ result: TranscriptHarvestResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result.outputRows())
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
