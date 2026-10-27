import CmuxNextWakeups
public import Foundation

/// The memory store's own import and export (`optchat-chief memory`,
/// Native/OptChat memory_cli.rs): the migration reads an old memory and
/// writes the Chief home's through the store, never its database file.
public protocol ChiefMemoryTool: Sendable {
    /// `memory export --text DIR`: the memory as JSONL day files (main/, tree/).
    nonisolated func exportText(muxHome: URL, to directory: URL) async throws
    /// `memory import DIR`: JSONL day files into an empty memory (host stopped).
    nonisolated func importText(muxHome: URL, from directory: URL) async throws
}

/// The `optchat-chief` this build bundles (Contents/Resources/bin).
public nonisolated struct BundledChiefMemoryTool: ChiefMemoryTool {
    let executable: URL
    /// Runs the tool to its end (``AsyncProcess``; tests pass a fake).
    var processes: any ProcessRunning = AsyncProcess()

    /// The bundled tool, or nil when the build has none (Release, RC).
    public static func bundled(bin: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)) -> BundledChiefMemoryTool? {
        guard let path = bin?.appendingPathComponent(HomeBrainHost.bundledChiefName),
              FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return BundledChiefMemoryTool(executable: path)
    }

    public func exportText(muxHome: URL, to directory: URL) async throws {
        try await run(["memory", "export", "--text", directory.path, "--mux-home", muxHome.path], onCancel: .stop)
    }

    public func importText(muxHome: URL, from directory: URL) async throws {
        try await run(["memory", "import", "--mux-home", muxHome.path, directory.path], onCancel: .finish)
    }

    /// Runs the tool to its exit without blocking a thread: the spawn runs off the caller's actor
    /// and the exit resumes the caller. Home waits for the migration, so it runs at userVisible.
    /// `onCancel`: an export only writes its scratch folder, so a cancel may stop it; an import writes
    /// the Chief home's memory, which must not be left half filled, so it always runs to its exit.
    @concurrent private func run(_ arguments: [String], onCancel: ProcessRequest.CancelBehavior) async throws {
        let request = ProcessRequest(executable, arguments, errorOutput: .separate, onCancel: onCancel, priority: .userVisible)
        let outcome = try await processes.outcome(of: request)
        guard outcome.succeeded else {
            let text = String(decoding: outcome.errorOutput, as: UTF8.self)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "optchat-chief \(arguments.prefix(2).joined(separator: " ")): \(text)"])
        }
    }
}
