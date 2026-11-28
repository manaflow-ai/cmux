// The CmuxNextWindowRules wire types that cmux-tui/bindings/codegen/swift_ffi/window_rules.json lists are not in
// git (RFD 0048): every build writes them from the Rust crate cmux-tui/crates/cmux-window-rules with
// cmux-tui/bindings/codegen/swift_ffi/generate.py, which rewrites only a changed file, so an incremental build
// recompiles nothing it did not change. Rust is the single source of the FFI's request and reply shapes. They go to
// the plugin's work directory, never the target's own folder (SwiftPM would compile a second copy there).
import Foundation
import PackagePlugin

@main
struct WindowRulesWireTypesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // The package is Packages/macOS/CmuxNext; the generator and the crate are at the repo root.
        let repo = context.package.directoryURL.appending(path: "../../..").standardized
        let script = repo.appending(path: "cmux-tui/bindings/codegen/swift_ffi/generate.py")
        let bindings = repo.appending(path: "cmux-tui/bindings/codegen/swift_ffi/window_rules.json")
        let out = context.pluginWorkDirectoryURL.appending(path: "WireTypes")
        return [
            .prebuildCommand(
                displayName: "Generate the CmuxNextWindowRules wire types from cmux-tui/crates/cmux-window-rules",
                // The same interpreter pick as DaemonWireTypesPlugin: Xcode runs plugins with PATH=/usr/bin:/bin,
                // whose python3 is macOS's 3.9, and the generator needs 3.10+.
                executable: URL(filePath: "/bin/sh"),
                // -B: no __pycache__ beside the generator (a plugin may write only its work directory).
                arguments: [
                    "-c", Self.pickPython, "sh", script.path(percentEncoded: false), out.path(percentEncoded: false),
                    bindings.path(percentEncoded: false),
                ],
                outputFilesDirectory: out
            ),
        ]
    }

    static let pickPython = #"""
    names="python3 python3.14 python3.13 python3.12 python3.11 python3.10"
    for py in $(for dir in /opt/homebrew/bin /usr/local/bin \
        /Library/Frameworks/Python.framework/Versions/Current/bin; do
        for name in $names; do echo "$dir/$name"; done; done) \
        $(for name in $names; do command -v "$name"; done); do
        [ -n "$py" ] && [ -x "$py" ] || continue
        "$py" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || continue
        exec "$py" -I -B "$1" --out "$2" --bindings "$3"
    done
    echo "error: WindowRulesWireTypesPlugin needs Python 3.10+ (brew install python)" >&2
    exit 1
    """#
}
