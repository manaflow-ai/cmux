import Foundation

/// The memory store's own import and export (`optchat-chief memory`,
/// Native/OptChat memory_cli.rs): the migration reads an old memory and
/// writes the Chief home's through the store, never its database file.
protocol ChiefMemoryTool: Sendable {
    /// `memory export --text DIR`: the memory as JSONL day files (main/, tree/).
    func exportText(muxHome: URL, to directory: URL) throws
    /// `memory import DIR`: JSONL day files into an empty memory (host stopped).
    func importText(muxHome: URL, from directory: URL) throws
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

    func exportText(muxHome: URL, to directory: URL) throws {
        try run(["memory", "export", "--text", directory.path, "--mux-home", muxHome.path])
    }

    func importText(muxHome: URL, from directory: URL) throws {
        try run(["memory", "import", "--mux-home", muxHome.path, directory.path])
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "optchat-chief \(arguments.prefix(2).joined(separator: " ")): \(text)"])
        }
    }
}
