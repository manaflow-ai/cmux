import CmuxNextInputModel
import Foundation

/// The first line of a saved `.jsonl` journal (scripts/cmux-next/oracle/driver_app.py writes it at the end of
/// each corpus case): which case and build recorded the entries after it.
struct JournalHeader: Codable, Hashable, Sendable {
    static let currentSchema = "cmux-input-journal-v1"

    var schema: String
    /// The corpus case (`<suite>/<case>`) whose run recorded the journal.
    var source: String?
    /// The app commit that recorded it.
    var sha: String?
}

/// One journal to replay: its entries, oldest first, and where each came from.
struct Journal: Sendable {
    /// `journals/<path under the input directory, without its extension>`, the case id diff.py compares.
    var caseID: String
    var path: String
    var header: JournalHeader?
    var entries: [InputJournalEntry]
    /// The file line of each entry (a `.jsonl` journal), by `seq`: a divergence's evidence.
    var lines: [UInt64: Int] = [:]
}

/// Reads journals in the shapes the app gives them: a saved `.jsonl` (an optional header, one entry per line),
/// or a `.json` entry array, desync report (`journal`), or `debug.journal` reply (`entries`, or the whole reply's
/// `result.entries`).
struct JournalReader {
    /// One journal file and the case it is.
    struct Input: Hashable, Sendable {
        var file: String
        var caseID: String
    }

    private struct Document: Decodable {
        struct Reply: Decodable {
            var entries: [InputJournalEntry]?
        }

        var journal: [InputJournalEntry]?
        var entries: [InputJournalEntry]?
        var result: Reply?
    }

    private let decoder = JSONDecoder()

    /// Every journal file under `paths`, a directory's in path order. Two inputs that name the same case are
    /// refused: the receipt keys results by case.
    func inputs(at paths: [String]) throws(OracleReplayError) -> [Input] {
        var out: [Input] = []
        var seen: [String: String] = [:]
        for path in paths {
            for (file, name) in try files(at: path) {
                let input = Input(file: file, caseID: "journals/" + name)
                if let first = seen[input.caseID] {
                    throw .usage("\(file) and \(first) are both case \(input.caseID)")
                }
                seen[input.caseID] = file
                out.append(input)
            }
        }
        return out
    }

    /// The journal files at `path` with their case names: the file itself, or a directory's `.json` and `.jsonl`
    /// files by relative path (names starting with `_` or `.` are not journals).
    private func files(at path: String) throws(OracleReplayError) -> [(file: String, name: String)] {
        let url = URL(fileURLWithPath: path)
        let isDirectory: Bool
        do {
            // blocking-allow: host oracle tool, not the app; no app thread to block.
            isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
        } catch {
            throw .unreadable(path: path, reason: String(describing: error))
        }
        guard isDirectory else { return [(path, Self.stem(url.lastPathComponent))] }
        let relative: [String]
        do {
            // blocking-allow: host oracle tool, not the app; no app thread to block.
            relative = try FileManager.default.subpathsOfDirectory(atPath: path)
        } catch {
            throw .unreadable(path: path, reason: String(describing: error))
        }
        return relative.sorted().compactMap { sub -> (file: String, name: String)? in
            let name = sub.split(separator: "/").last.map(String.init) ?? sub
            guard sub.hasSuffix(".jsonl") || sub.hasSuffix(".json"), !name.hasPrefix("_"), !name.hasPrefix(".") else {
                return nil
            }
            return (url.appendingPathComponent(sub).path, Self.stem(sub))
        }
    }

    private static func stem(_ name: String) -> String {
        for suffix in [".jsonl", ".json"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    func load(_ input: Input) throws(OracleReplayError) -> Journal {
        let path = input.file
        let data: Data
        do {
            // blocking-allow: host oracle tool, not the app; no app thread to block.
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: String(describing: error))
        }
        if path.hasSuffix(".jsonl") { return try jsonLines(data, path: path, caseID: input.caseID) }
        let entries = try document(data, path: path)
        return Journal(caseID: input.caseID, path: path, entries: entries)
    }

    /// A `.jsonl` journal. Its entry lines decode as one array (a decoder call per line costs more than the
    /// replay); when that fails, line by line, so the error names its line.
    private func jsonLines(_ data: Data, path: String, caseID: String) throws(OracleReplayError) -> Journal {
        var journal = Journal(caseID: caseID, path: path, entries: [])
        var lines: [(number: Int, text: Data)] = []
        for (index, line) in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).enumerated()
        where line.contains(where: { !Self.isSpace($0) }) {
            lines.append((index + 1, Data(line)))
        }
        if let first = lines.first, let header = try? decoder.decode(JournalHeader.self, from: first.text) {
            guard header.schema == JournalHeader.currentSchema else {
                throw .malformed(path: path, line: first.number,
                                 reason: "journal schema \(header.schema), expected \(JournalHeader.currentSchema)")
            }
            journal.header = header
            lines.removeFirst()
        }
        var array = Data("[".utf8)
        for (offset, line) in lines.enumerated() {
            if offset > 0 { array.append(UInt8(ascii: ",")) }
            array.append(line.text)
        }
        array.append(UInt8(ascii: "]"))
        if let entries = try? decoder.decode([InputJournalEntry].self, from: array) {
            journal.entries = entries
        } else {
            for line in lines {
                let decoded = try entry(line.text, path: path, line: line.number)
                journal.entries.append(decoded)
            }
        }
        for (entry, line) in zip(journal.entries, lines) {
            journal.lines[entry.seq] = line.number
        }
        return journal
    }

    private func entry(_ text: Data, path: String, line: Int) throws(OracleReplayError) -> InputJournalEntry {
        do {
            return try decoder.decode(InputJournalEntry.self, from: text)
        } catch {
            throw .malformed(path: path, line: line, reason: "not a journal entry: \(error)")
        }
    }

    private func document(_ data: Data, path: String) throws(OracleReplayError) -> [InputJournalEntry] {
        do {
            if data.first(where: { !Self.isSpace($0) }) == UInt8(ascii: "[") {
                return try decoder.decode([InputJournalEntry].self, from: data)
            }
            let document = try decoder.decode(Document.self, from: data)
            if let entries = document.journal ?? document.entries ?? document.result?.entries { return entries }
        } catch {
            throw .malformed(path: path, line: nil, reason: "not a journal: \(error)")
        }
        throw .malformed(path: path, line: nil,
                         reason: "no journal: expected an entry array, a desync report (journal) or a debug.journal reply (entries)")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}
