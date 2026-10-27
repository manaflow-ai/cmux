import CLibFuzzer
import Foundation

/// One coverage-guided fuzz target (p10-stability-182): a `@_cdecl("LLVMFuzzerTestOneInput")`
/// function that hands each input to a test body, and the libFuzzer driver around it, as
/// Chromium's `fuzzer_test` targets do (testing/libfuzzer/README.md). The body is a property
/// suite's `oneInput(_:)` (CmuxFuzzSupport), or a decoder fed the raw bytes.
public struct LibFuzzerTarget: Sendable {
    /// The C entry libFuzzer calls once per input.
    public typealias Entry = @convention(c) (UnsafePointer<UInt8>?, Int) -> CInt

    /// The corpus directory name under the corpus root. A target that wraps a suite's
    /// `oneInput(_:)` uses the suite's run name, so `CMUX_FUZZ_CORPUS/<corpus>/` feeds the
    /// property test and the fuzzer alike.
    public let corpus: String
    /// Inputs written to the corpus before the first run: one per branch of the body. Byte
    /// arrays, not `Data`: LeakSanitizer does not see the tagged reference inside a `Data` held by
    /// a global, and would report each seed as a leak at exit.
    public let seeds: [[UInt8]]

    public init(corpus: String, seeds: [[UInt8]] = []) {
        self.corpus = corpus
        self.seeds = seeds
    }

    /// Runs `body` on one input. A thrown error is a finding: the process aborts, so libFuzzer
    /// keeps the input as a crash artifact, as it does for a trap.
    public static func test(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ body: (Data) throws -> Void) -> CInt {
        // SAFETY: libFuzzer passes `count` readable bytes at `bytes`, alive for this call; Data copies them.
        let data = unsafe bytes.map { unsafe Data(bytes: $0, count: count) } ?? Data()
        do {
            try body(data)
        } catch {
            FileHandle.standardError.write(Data("libfuzzer target: the input failed a property: \(error)\n".utf8))
            abort()
        }
        return 0
    }

    /// The process's main: `--cmux-corpus-name` prints ``corpus``, `--cmux-write-seeds DIR`
    /// writes ``seeds`` into DIR; any other arguments go to libFuzzer.
    public func main(_ entry: Entry) -> Never {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--cmux-corpus-name" {
            FileHandle.standardOutput.write(Data((corpus + "\n").utf8))
            exit(0)
        }
        if arguments.count == 3, arguments[1] == "--cmux-write-seeds" {
            exit(writeSeeds(into: URL(fileURLWithPath: arguments[2], isDirectory: true)))
        }
        var argc = CommandLine.argc
        // SAFETY: the process's own argc and argv, which libFuzzer reads (and may shorten) once.
        var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = unsafe CommandLine.unsafeArgv
        exit(unsafe LLVMFuzzerRunDriver(&argc, &argv, entry))
    }

    /// Writes `seed-<n>` files (the same names each time, so a rerun adds nothing); 0 or 1.
    private func writeSeeds(into directory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, seed) in seeds.enumerated() {
                try Data(seed).write(to: directory.appendingPathComponent("seed-\(index)"))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("libfuzzer target: cannot write seeds to \(directory.path): \(error)\n".utf8))
            return 1
        }
    }
}
