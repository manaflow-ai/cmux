import Foundation

enum TranscriptHarvestArgumentError: Error, CustomStringConvertible {
    case help
    case invalidValue(String)
    case missingValue(String)
    case unknownFlag(String)

    var description: String {
        switch self {
        case .help:
            """
            usage: agent-transcript-harvest [--claude-root PATH] [--codex-root PATH] [--max-files N] [--format tsv|json] [--recent-days N]
            --max-files applies per source. DECODER-GAP means decoders counted >= 1 occurrence as unknown; exact counts are in decoder_unknown rows.
            """
        case .invalidValue(let flag):
            "invalid value for \(flag)"
        case .missingValue(let flag):
            "missing value after \(flag)"
        case .unknownFlag(let flag):
            "unknown flag \(flag)"
        }
    }
}
