// The CmuxNextDaemon request types that cmux-tui/bindings/codegen/swift_app/bindings.json lists are not in
// git (RFD 0048): every build writes them from cmux-tui/spec/sdk-schema.json with
// cmux-tui/bindings/codegen/swift_app/generate.py, which rewrites only changed files, so an incremental build
// recompiles nothing it did not change. They go to the plugin's work directory, never the target's own folder
// (SwiftPM would compile a second copy there).
import Foundation
import PackagePlugin

@main
struct DaemonWireTypesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and the schema are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "cmux-tui/bindings/codegen/swift_app/generate.py")
        let out = context.pluginWorkDirectoryURL.appending(path: "Requests")
        return [
            .prebuildCommand(
                displayName: "Generate the CmuxNextDaemon request types from cmux-tui/spec/sdk-schema.json",
<<<<<<< HEAD
                executable: URL(filePath: "/usr/bin/env"),
                // -B: no __pycache__ beside the generator (a plugin may write only its work directory).
                arguments: ["python3", "-I", "-B", script.path(percentEncoded: false), "--out", out.path(percentEncoded: false)],
=======
                // The generator shares cmux-tui/bindings/codegen, which needs Python 3.10+ (dataclass slots), and
                // Xcode runs plugins with PATH=/usr/bin:/bin, whose python3 is macOS's 3.9. Take the first 3.10+
                // interpreter from Homebrew, python.org or PATH, and fail naming the fix when there is none.
                executable: URL(filePath: "/bin/sh"),
                // -B: no __pycache__ beside the generator (a plugin may write only its work directory).
                arguments: ["-c", Self.pickPython, "sh", script.path(percentEncoded: false), out.path(percentEncoded: false)],
>>>>>>> origin/feat-cmux-next
                outputFilesDirectory: out
            ),
        ]
    }
<<<<<<< HEAD
=======

    static let pickPython = #"""
    for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
        "$(command -v python3.13)" "$(command -v python3.12)" "$(command -v python3.11)" \
        "$(command -v python3.10)" "$(command -v python3)"; do
        [ -n "$py" ] && [ -x "$py" ] || continue
        "$py" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || continue
        exec "$py" -I -B "$1" --out "$2"
    done
    echo "error: DaemonWireTypesPlugin needs Python 3.10+ (brew install python)" >&2
    exit 1
    """#
>>>>>>> origin/feat-cmux-next
}
