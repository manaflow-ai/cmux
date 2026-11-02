import Foundation
import PackagePlugin

/// Generates the CmuxNextDaemon request types that cmux-tui/bindings/codegen/swift_app/bindings.json lists, from
/// cmux-tui/spec/sdk-schema.json, before every build of the target. SwiftPM compiles the files it writes to the
/// plugin's work folder; they are never committed (scripts/ci/generated_files_guard.py) and never written into
/// the target's own folder, which would compile them twice.
///
/// It runs the repository's Python generator with the first `python3` it finds (Xcode's command line tools put one
/// at /usr/bin/python3; the Linux builders have one on PATH). With none, the build stops here with an error that
/// says so: it never compiles stale or missing types.
@main
struct DaemonWireTypes: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // Packages/macOS/CmuxNext -> the repository root.
        let repository = context.package.directoryURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let generator = repository.appending(path: "cmux-tui/bindings/codegen/swift_app/generate.py")
        guard FileManager.default.fileExists(atPath: generator.path) else {
            throw DaemonWireTypesError.missing("the generator \(generator.path)")
        }
        // SwiftPM compiles only the files directly in this folder (generate.py --out writes no subfolders).
        let output = context.pluginWorkDirectoryURL.appending(path: "Generated")
        let python = try Self.python()
        Diagnostics.remark("DaemonWireTypes: \(python.path) \(generator.path) --out \(output.path)")
        return [
            .prebuildCommand(
                displayName: "Generate the CmuxNextDaemon wire types from sdk-schema.json",
                executable: python,
                // -I: ignore PYTHON* variables and the user's site packages; -B: write no __pycache__ beside the
                // generator (the plugin may write only its work folder).
                arguments: ["-I", "-B", generator.path, "--out", output.path],
                outputFilesDirectory: output
            ),
        ]
    }

    /// The first `python3` among the system locations and PATH.
    private static func python() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        for folder in candidates where !folder.isEmpty {
            let python = URL(fileURLWithPath: folder).appending(path: "python3")
            if FileManager.default.isExecutableFile(atPath: python.path) { return python }
        }
        throw DaemonWireTypesError.missing(
            "python3 (looked in /usr/bin, /opt/homebrew/bin, /usr/local/bin and PATH); on a Mac run `xcode-select --install`"
        )
    }
}

/// Why the plugin could not plan the generation; SwiftPM shows the description as the build error.
enum DaemonWireTypesError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let what):
            "DaemonWireTypes cannot generate the CmuxNextDaemon wire types: missing \(what)."
        }
    }
}
