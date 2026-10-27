import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One corpus file: its path relative to the corpus and its text.
struct CorpusSource: Sendable {
    let file: String
    let text: String
}

/// The run's disk I/O, on the files lane of the run's `BackgroundWork` (never the main thread or the pool).
struct CorpusFiles: Sendable {
    let options: DumpOptions
    let work: BackgroundWork

    /// Every `.jsonc` file under the corpus, sorted by UTF-8 path (the Rust dump's order).
    func read() async throws(DumpError) -> [CorpusSource] {
        let root = options.corpus
        return try await onFilesLane(root) { () throws(DumpError) -> [CorpusSource] in try Self.readAll(root) }
    }

    /// Writes the dump to `--out`, or to standard output.
    func write(_ text: String) async throws(DumpError) {
        let out = options.out
        try await onFilesLane(out ?? options.corpus) { () throws(DumpError) in try Self.write(Data(text.utf8), to: out) }
    }

    private func onFilesLane<T: Sendable>(_ url: URL, _ body: @escaping @Sendable () throws(DumpError) -> T) async throws(DumpError) -> T {
        do {
            return try await work.run(.userVisible, mayBlock: .files) { try body() }
        } catch let error as DumpError {
            throw error
        } catch {
            throw .unreadable(path: url.path, reason: String(describing: error))
        }
    }

    private static func readAll(_ root: URL) throws(DumpError) -> [CorpusSource] {
        let paths: [String]
        do {
            paths = try FileManager.checked.subpathsOfDirectory(atPath: root.path)
        } catch {
            throw .unreadable(path: root.path, reason: String(describing: error))
        }
        let files = paths.filter { $0.hasSuffix(".jsonc") }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var sources: [CorpusSource] = []
        sources.reserveCapacity(files.count)
        for file in files {
            let url = root.appending(path: file)
            let bytes: Data
            do {
                bytes = try Data(blockingContentsOf: url)
            } catch {
                throw .unreadable(path: url.path, reason: String(describing: error))
            }
            // Lossy like the Rust side's `from_utf8_lossy`: a bad byte is a value both read the same.
            sources.append(CorpusSource(file: file, text: String(decoding: bytes, as: UTF8.self)))
        }
        return sources
    }

    private static func write(_ data: Data, to out: URL?) throws(DumpError) {
        guard let out else {
            FileHandle.standardOutput.blockingWrite(data)
            return
        }
        do {
            try data.blockingWrite(to: out)
        } catch {
            throw .unreadable(path: out.path, reason: String(describing: error))
        }
    }
}
