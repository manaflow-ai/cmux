import Foundation

/// Failing inputs under `CMUX_FUZZ_ARTIFACTS`, as libFuzzer's `-artifact_prefix`
/// keeps `crash-<sha>` files. A trap ends the test process before any handler can
/// write, so the current input is written before each iteration
/// (`<name>.inflight`, `<name>.inflight.input`) and is still there after the
/// crash; a finished run removes those files. A thrown failure is kept as
/// `<name>-<seed>-<iteration>.txt` (and `.input`). The files are named by the run
/// name, so two runs that go at the same time need two names (a parameterized test
/// puts its argument in the name).
struct FuzzArtifacts {
    let directory: URL
    let base: String
    private let record: FileHandle
    private let input: FileHandle

    init(directory: URL, name: String) throws(FuzzError) {
        self.directory = directory
        base = Self.fileName(for: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            record = try Self.open(directory.appendingPathComponent("\(base).inflight"))
            input = try Self.open(directory.appendingPathComponent("\(base).inflight.input"))
        } catch {
            throw FuzzError.artifactUnwritable(path: directory.path, reason: String(describing: error))
        }
    }

    /// A file name for a run name: letters, digits, `.`, `-` and `_` stay, anything else becomes `_`.
    static func fileName(for name: String) -> String {
        let kept = name.unicodeScalars.map { scalar -> Character in
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            return allowed ? Character(scalar) : "_"
        }
        let text = String(kept)
        return text.isEmpty || text.allSatisfy({ $0 == "." }) ? "run" : text
    }

    /// Records the iteration about to run and its replay line, so a trap leaves them behind.
    func noteInflight(seed: UInt64, iteration: Int, replay: String, input bytes: Data?) throws(FuzzError) {
        let line = "name=\(base) seed=0x\(String(seed, radix: 16)) iteration=\(iteration)\nreplay: \(replay)\n"
        do {
            try Self.overwrite(record, with: Data(line.utf8))
            try Self.overwrite(input, with: bytes ?? Data())
        } catch {
            throw FuzzError.artifactUnwritable(path: directory.path, reason: String(describing: error))
        }
    }

    /// Keeps a thrown failure and returns the path of its `.txt` record.
    func keep(_ failure: FuzzFailure) throws(FuzzError) -> URL {
        let stem = "\(base)-\(String(failure.seed, radix: 16))-\(failure.iteration)"
        let text = directory.appendingPathComponent("\(stem).txt")
        do {
            try Data((failure.description + "\n").utf8).write(to: text)
            if let bytes = failure.input {
                try bytes.write(to: directory.appendingPathComponent("\(stem).input"))
            }
        } catch {
            throw FuzzError.artifactUnwritable(path: text.path, reason: String(describing: error))
        }
        return text
    }

    /// Closes and removes the in-flight files (the run ended without a trap).
    func finish() {
        try? record.close()
        try? input.close()
        for suffix in [".inflight", ".inflight.input"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(base + suffix))
        }
    }

    private static func open(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FuzzError.artifactUnwritable(path: url.path, reason: "cannot create the file")
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func overwrite(_ handle: FileHandle, with data: Data) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
    }
}
