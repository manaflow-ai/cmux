public import Foundation

/// One run of the app's bundled `cmux` CLI (``BundledExecutable/cli(resources:work:)``) off the main
/// actor, bounded: the cmux Live actions (`cmux live start|stop`) and turning a code layer off after
/// a page did not start from it.
public struct BundledCLIRun {
    public init() {}
    /// Runs `cli` with `arguments` for at most `timeout`, keeping the last 64 KiB of each stream;
    /// nil when it could not start or did not finish in time.
    @concurrent public static func run(_ cli: URL, _ arguments: [String], timeout: Duration) async -> ProcessResult? {
        try? await ProcessRunner.run(executable: cli, arguments: arguments, environment: nil, timeout: timeout,
                                     outputTailBytes: 64 * 1024, clock: ContinuousClock())
    }

    /// The last line of `data`, nil when it has none.
    public nonisolated static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
    }

    /// Turns the code layer off with `cmux customize library off --code --reason REASON`, which
    /// records `reason` on the entry. Nil when it did; else why not (no CLI, its error, no finish).
    public static func turnCodeLayerOff(_ bundled: BundledExecutable, reason: String) async -> String? {
        guard let cli = await bundled.resolve() else { return "this build has no cmux CLI" }
        guard let result = await run(cli, ["customize", "library", "off", "--code", "--reason", reason], timeout: .seconds(30)) else {
            return "cmux customize library off --code did not finish"
        }
        guard result.status != 0 else { return nil }
        return lastLine(result.stderr) ?? "cmux customize library off --code exited \(result.status)"
    }
}
