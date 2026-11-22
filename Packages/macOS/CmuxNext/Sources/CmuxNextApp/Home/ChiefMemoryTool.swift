import Foundation

/// The memory store's own import and export (`optchat-chief memory`,
/// Native/OptChat memory_cli.rs): the migration reads an old memory and
/// writes the Chief home's through the store, never its database file.
protocol ChiefMemoryTool: Sendable {
    /// `memory export --text DIR`: the memory as JSONL day files (main/, tree/).
    nonisolated func exportText(muxHome: URL, to directory: URL) async throws
    /// `memory import DIR`: JSONL day files into an empty memory (host stopped).
    nonisolated func importText(muxHome: URL, from directory: URL) async throws
}

/// The `optchat-chief` this build bundles (Contents/Resources/bin).
nonisolated struct BundledChiefMemoryTool: ChiefMemoryTool {
    let executable: URL

    /// The bundled tool, or nil when the build has none (Release, RC).
    static func bundled(bin: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)) -> BundledChiefMemoryTool? {
        guard let path = bin?.appendingPathComponent(HomeBrainHost.bundledChiefName),
              FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return BundledChiefMemoryTool(executable: path)
    }

    func exportText(muxHome: URL, to directory: URL) async throws {
        try await run(["memory", "export", "--text", directory.path, "--mux-home", muxHome.path])
    }

    func importText(muxHome: URL, from directory: URL) async throws {
        try await run(["memory", "import", "--mux-home", muxHome.path, directory.path])
    }

    /// Runs the tool to its exit without blocking a thread: the exit
    /// resumes the caller; its error output goes to a scratch file.
    @concurrent private func run(_ arguments: [String]) async throws {
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("optchat-chief-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard process.terminationStatus == 0 else {
            // concurrency-allow: @concurrent: runs on the global executor, never the main actor
            let text = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "optchat-chief \(arguments.prefix(2).joined(separator: " ")): \(text)"])
        }
    }
}
