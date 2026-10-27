import Foundation

/// The stored corpus of one fuzz family, as `scripts/cmux-next/fuzz-corpus.py` keeps it: ClusterFuzz's
/// persistent corpus per target (`corpus_pruning_task.py`), which every run starts from and stores back
/// minimized.
///
///     <root>/inputs/<name>/<sha1>       one input per file (CMUX_FUZZ_CORPUS=<root>/inputs)
///     <root>/meta/<name>.json           {"generation", "count", "bytes", ...}
///
/// A suite's long-mode run reads the stored inputs through ``environment(_:)``; a coverage-guided
/// libFuzzer target (p10-stability-182) is handed `inputs(for:)` as its corpus directory, and its
/// script pulls and pushes the store with fuzz-corpus.py.
public struct FuzzCorpusStore: Sendable, Equatable {
    /// The largest input that may be checked in, as a seed or as a regression next to its fix
    /// (`fuzz-corpus.py check` and `regress` enforce the same limit). Stored corpora have no limit.
    public static let maxCheckedInInputBytes = 64 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// What the store holds for one name, from its meta file.
    public struct Summary: Sendable, Equatable, Decodable {
        /// Counts the pushes, so a run can tell that another run stored the corpus after it read it.
        public var generation: Int
        public var count: Int
        public var bytes: Int

        public init(generation: Int, count: Int, bytes: Int) {
            self.generation = generation
            self.count = count
            self.bytes = bytes
        }
    }

    /// `<root>/inputs`, the `CMUX_FUZZ_CORPUS` of a run that starts from this store.
    public var inputsRoot: URL {
        root.appendingPathComponent("inputs", isDirectory: true)
    }

    /// The directory of one name's stored inputs.
    public func inputs(for name: String) -> URL {
        inputsRoot.appendingPathComponent(FuzzArtifacts.fileName(for: name), isDirectory: true)
    }

    /// `environment` reading its stored inputs from this store.
    public func environment(_ base: FuzzEnvironment) -> FuzzEnvironment {
        var environment = base
        environment.corpus = inputsRoot
        return environment
    }

    /// What is stored for `name`; nil when the store has nothing for it. A meta file that does not
    /// decode is an error, never an empty corpus.
    public func summary(for name: String) throws(FuzzError) -> Summary? {
        let meta = root.appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("\(FuzzArtifacts.fileName(for: name)).json")
        guard FileManager.default.fileExists(atPath: meta.path) else { return nil }
        do {
            return try JSONDecoder().decode(Summary.self, from: Data(contentsOf: meta))
        } catch {
            throw FuzzError.corpusUnreadable(path: meta.path, reason: String(describing: error))
        }
    }
}

extension FuzzCorpus {
    /// The checked-in regression inputs of a run: every regular file of `<directory>/<name>/` in name
    /// order, hidden files skipped (`fuzz-corpus.py regress --corpus-dir <directory>` writes them, one per
    /// fixed finding). A missing directory adds nothing; a file over
    /// ``FuzzCorpusStore/maxCheckedInInputBytes`` is an error, so a large crash input is minimized
    /// before it is committed.
    public static func regressions(name: String, in directory: URL) throws(FuzzError) -> [Data] {
        let folder = directory.appendingPathComponent(FuzzArtifacts.fileName(for: name), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
        } catch {
            throw FuzzError.corpusUnreadable(path: folder.path, reason: String(describing: error))
        }
        var inputs: [Data] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !file.lastPathComponent.hasPrefix(".") else { continue }
            let data: Data
            do {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                if let size = values.fileSize, size > FuzzCorpusStore.maxCheckedInInputBytes {
                    throw FuzzError.corpusInputTooLarge(path: file.path, bytes: size)
                }
                data = try Data(contentsOf: file)
            } catch let error as FuzzError {
                throw error
            } catch {
                throw FuzzError.corpusUnreadable(path: file.path, reason: String(describing: error))
            }
            guard data.count <= FuzzCorpusStore.maxCheckedInInputBytes else {
                throw FuzzError.corpusInputTooLarge(path: file.path, bytes: data.count)
            }
            inputs.append(data)
        }
        return inputs
    }

    /// The bytes of every input.
    public var byteCount: Int {
        inputs.reduce(0) { $0 + $1.count }
    }

    /// One line for the run's log, which shows that a run started from its stored corpus:
    /// `Suite.case: starts from 12 inputs (3456 bytes)`.
    public func startLine(name: String) -> String {
        "\(name): starts from \(inputs.count) inputs (\(byteCount) bytes)"
    }
}
