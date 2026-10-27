public import CmuxNextWakeups
public import Foundation

/// `optchat-chief usage` (Native/OptChat, plans/cmux-next/chief-usage-analytics-DESIGN.md): the
/// usage summary of this Mac's Chiefs, read from their usage ledgers. The brain need not run.
///
/// The tool is `CMUX_OPTCHAT_CHIEF` when set (as for `cmux chief usage`), else a local
/// `optchat-chief` build named by `CMUX_NEXT_MUX_HOST`, else the one this build bundles
/// (Contents/Resources/bin; DEV and NIGHTLY only).
///
/// ```swift
/// if let tool = ChiefUsageTool.resolve() {
///     let json = try await tool.run(["usage", "--since", "7d"], muxHome: home)
/// }
/// ```
public nonisolated struct ChiefUsageTool: Sendable {
    /// The `optchat-chief` executable.
    public let executable: URL

    /// A run that exited non-zero.
    public nonisolated struct Failure: Error, Sendable, Equatable {
        /// The exit status.
        public let status: Int32
        /// Standard error, trimmed.
        public let message: String
    }

    /// Runs the tool to its end (``AsyncProcess``; tests pass a fake).
    let processes: any ProcessRunning

    /// - Parameters:
    ///   - executable: The `optchat-chief` to run.
    ///   - processes: What runs it; ``AsyncProcess`` by default.
    public init(executable: URL, processes: any ProcessRunning = AsyncProcess()) {
        self.executable = executable
        self.processes = processes
    }

    /// The tool this app runs, or nil when there is none (Release and RC bundle no Chief).
    /// - Parameters:
    ///   - environment: Read for `CMUX_OPTCHAT_CHIEF` and `CMUX_NEXT_MUX_HOST`.
    ///   - bin: The app's bundled tool directory (Contents/Resources/bin).
    /// - Returns: The first executable candidate, or nil.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               bin: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)) -> ChiefUsageTool? {
        let explicit = environment["CMUX_OPTCHAT_CHIEF"].flatMap { $0.isEmpty ? nil : $0 }
        // A `CMUX_NEXT_MUX_HOST` that is the TypeScript mux has no `usage`: only an optchat-chief build counts.
        let host = environment["CMUX_NEXT_MUX_HOST"].flatMap { URL(fileURLWithPath: $0).lastPathComponent == HomeBrainHost.bundledChiefName ? $0 : nil }
        let bundled = bin?.appendingPathComponent(HomeBrainHost.bundledChiefName).path
        guard let path = [explicit, host, bundled].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return ChiefUsageTool(executable: URL(fileURLWithPath: path))
    }

    /// Runs the tool with `arguments`, then `--mux-home muxHome --chiefs --json` (the home's
    /// Chief and every Chief under it), and returns its standard output. Nothing waits on a thread:
    /// the spawn runs off the caller's actor and both pipes drain while it runs, so a large summary
    /// never blocks the tool. The usage page shows the answer, so the tool runs at userVisible.
    /// - Parameters:
    ///   - arguments: The tool's arguments (`usage --since 7d --by chief`).
    ///   - muxHome: This build's Chief home (`HomeBrainHost.muxHome(tag:)`).
    /// - Returns: The tool's standard output.
    /// - Throws: ``Failure`` on a non-zero exit, or ``ProcessFailure/launch(_:)``.
    @concurrent public func run(_ arguments: [String], muxHome: URL) async throws -> Data {
        let request = ProcessRequest(executable, arguments + ["--mux-home", muxHome.path, "--chiefs", "--json"],
                                     errorOutput: .separate, priority: .userVisible)
        let outcome = try await processes.outcome(of: request)
        guard outcome.succeeded else {
            let message = String(decoding: outcome.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(status: outcome.status, message: message)
        }
        return outcome.output
    }
}
