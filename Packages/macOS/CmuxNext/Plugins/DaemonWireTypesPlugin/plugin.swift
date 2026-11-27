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
                // The generator shares cmux-tui/bindings/codegen, which needs Python 3.10+ (dataclass slots), and
                // Xcode and SwiftPM run plugins with PATH=/usr/bin:/bin, whose python3 is macOS's 3.9. Take the first
                // 3.10+ interpreter at Homebrew's and python.org's absolute paths, then PATH, and fail naming where it
                // looked when there is none.
                executable: URL(filePath: "/bin/sh"),
                // -B: no __pycache__ beside the generator (a plugin may write only its work directory).
                arguments: ["-c", Self.pickPython, "sh", script.path(percentEncoded: false), out.path(percentEncoded: false)],
                outputFilesDirectory: out
            ),
        ]
    }

    /// Absolute paths first, newest first, then PATH. A Homebrew python installed as another formula's dependency links
    /// only its versioned names (bin/python3.13), never bin/python3, and the plugin's PATH holds neither Homebrew
    /// folder, so a `command -v python3.13` never finds it (aws-m4pro-1..3, 2026-11-27): each prefix's versioned names
    /// and its opt/python@3.X keg come before PATH.
    static let pickPython = #"""
    script=$1 out=$2
    pick() {
        [ -n "$1" ] && [ -x "$1" ] || return 1
        "$1" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || return 1
        exec "$1" -I -B "$script" --out "$out"
    }
    for prefix in /opt/homebrew /usr/local; do
        pick "$prefix/bin/python3"
        for v in 14 13 12 11 10; do pick "$prefix/bin/python3.$v"; done
        for v in 14 13 12 11 10; do pick "$prefix/opt/python@3.$v/libexec/bin/python3"; done
    done
    for v in 14 13 12 11 10; do pick "/Library/Frameworks/Python.framework/Versions/3.$v/bin/python3"; done
    pick /Library/Frameworks/Python.framework/Versions/Current/bin/python3
    for name in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do pick "$(command -v "$name")"; done
    echo "error: DaemonWireTypesPlugin needs Python 3.10+ (brew install python). Looked in /opt/homebrew and" \
        "/usr/local (bin/python3, bin/python3.14 to 3.10, opt/python@3.14 to 3.10/libexec/bin/python3)," \
        "/Library/Frameworks/Python.framework/Versions (3.14 to 3.10, Current) and PATH=$PATH" >&2
    exit 1
    """#
}
