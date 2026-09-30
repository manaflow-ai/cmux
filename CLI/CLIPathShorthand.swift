import Foundation

/// `cmux <path>` opens a workspace at a path. A bare word is always a
/// command, never a path: a folder that holds a directory with a command's
/// name (the repo root's `App/` against the generated `cmux app …` verbs,
/// matched case-insensitively by the file system) must not turn the command
/// into "open a terminal there". A path needs an explicit form: `.`, `..`,
/// `./App`, `/abs`, `~/x`, `dir/sub`, or a file name with an extension
/// (`README.md`), or `cmux open App`.
enum CLIPathShorthand {
    /// True when `arg` has an explicit path form.
    static func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        return arg.contains("/")
    }

    /// True when `cmux <arg>` should open `arg` as a path. `exists` checks
    /// the resolved path.
    static func opensAsPath(_ arg: String, exists: (String) -> Bool) -> Bool {
        if looksLikePath(arg) { return true }
        guard !arg.hasPrefix("-"), !CLITopLevelCommands.names.contains(arg) else { return false }
        // A bare word with no extension is a command (listed, or an action
        // noun from the app's catalog), whatever the folder holds.
        guard arg.contains(".") else { return false }
        return exists(arg)
    }
}
