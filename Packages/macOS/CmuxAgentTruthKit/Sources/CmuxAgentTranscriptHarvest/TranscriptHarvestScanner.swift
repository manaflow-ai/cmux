import CmuxAgentReplica
import CmuxAgentTruthKit
package import Foundation

package struct TranscriptHarvestScanner {
    private let fileManager: FileManager

    package init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    package func scan(
        claudeRoot: URL,
        codexRoot: URL,
        maxFiles: Int?,
        modifiedSince: Date?
    ) -> TranscriptHarvestResult {
        var inventory = TranscriptShapeInventory()
        var gaps = TranscriptDecoderGapInventory()
        var summaries: [TranscriptHarvestSource: TranscriptHarvestSourceSummary] = [
            .claude: TranscriptHarvestSourceSummary(),
            .codex: TranscriptHarvestSourceSummary(),
        ]
        for source in TranscriptHarvestSource.allCases {
            let root = source == .claude ? claudeRoot : codexRoot
            let files = jsonlFiles(under: root, limit: maxFiles, modifiedSince: modifiedSince)
            for file in files {
                scanFile(file, source: source, inventory: &inventory, gaps: &gaps, summary: &summaries[source, default: TranscriptHarvestSourceSummary()])
            }
        }
        return TranscriptHarvestResult(
            rows: inventory.rows(gaps: gaps),
            summaries: summaries,
            decoderGapRows: gaps.summaryRows()
        )
    }

    private func jsonlFiles(under root: URL, limit: Int?, modifiedSince: Date?) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard limit.map({ files.count < $0 }) ?? true else {
                break
            }
            guard url.pathExtension == "jsonl" else {
                continue
            }
            guard isRecentEnough(url: url, modifiedSince: modifiedSince) else {
                continue
            }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func isRecentEnough(url: URL, modifiedSince: Date?) -> Bool {
        guard let modifiedSince else {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modificationDate = values?.contentModificationDate else {
            return true
        }
        return modificationDate >= modifiedSince
    }

    private func scanFile(
        _ url: URL,
        source: TranscriptHarvestSource,
        inventory: inout TranscriptShapeInventory,
        gaps: inout TranscriptDecoderGapInventory,
        summary: inout TranscriptHarvestSourceSummary
    ) {
        summary.filesScanned += 1
        var lineIndex = 0
        var claudeDecoder = ClaudeTranscriptDecoder()
        var codexDecoder = CodexTranscriptDecoder()
        do {
            let reader = try JSONLLineReader(url: url)
            defer {
                reader.close()
            }
            while let line = try reader.nextLine() {
                inventory.feed(source: source, rawLine: line)
                let diagnostics = decoderDiagnostics(
                    source: source,
                    line: line,
                    lineIndex: lineIndex,
                    claudeDecoder: &claudeDecoder,
                    codexDecoder: &codexDecoder
                )
                gaps.record(source: source, rawLine: line, diagnostics: diagnostics)
                summary.linesScanned += 1
                lineIndex += 1
            }
        } catch {
            summary.unreadableFiles += 1
        }
    }

    private func decoderDiagnostics(
        source: TranscriptHarvestSource,
        line: String,
        lineIndex: Int,
        claudeDecoder: inout ClaudeTranscriptDecoder,
        codexDecoder: inout CodexTranscriptDecoder
    ) -> TranscriptDecoderDiagnostics {
        switch source {
        case .claude:
            claudeDecoder.feed([line], startingAt: lineIndex, journalID: JournalID(rawValue: "harvest")).diagnostics
        case .codex:
            codexDecoder.feed([line], startingAt: lineIndex, journalID: JournalID(rawValue: "harvest")).diagnostics
        }
    }
}
