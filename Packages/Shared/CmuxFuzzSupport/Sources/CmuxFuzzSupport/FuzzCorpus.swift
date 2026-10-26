import Foundation

/// The inputs a run starts from: seeds written in the suite, then the stored files
/// in `CMUX_FUZZ_CORPUS/<name>/`, sorted by file name so the order is stable, hidden
/// files skipped. A libFuzzer target (p10-stability-182) reads the same directory.
public struct FuzzCorpus: Sendable, Equatable {
    public private(set) var inputs: [Data]

    public init(seeds: [Data]) {
        inputs = seeds
    }

    /// `seeds` plus every regular file in `<environment.corpus>/<name>/`. A corpus root or a
    /// name directory that does not exist adds nothing; a file that cannot be read is an error.
    public init(name: String, seeds: [Data], environment: FuzzEnvironment) throws(FuzzError) {
        inputs = seeds
        guard let root = environment.corpus else { return }
        let directory = root.appendingPathComponent(FuzzArtifacts.fileName(for: name), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            )
        } catch {
            throw FuzzError.corpusUnreadable(path: directory.path, reason: String(describing: error))
        }
        let visible = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        for file in visible.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                inputs.append(try Data(contentsOf: file))
            } catch {
                throw FuzzError.corpusUnreadable(path: file.path, reason: String(describing: error))
            }
        }
    }

    public var isEmpty: Bool { inputs.isEmpty }
}
