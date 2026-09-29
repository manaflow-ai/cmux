import Foundation

/// Maps a ``FileSearchQuery`` to ripgrep's command line.
///
/// The same argument vector runs locally, over SSH, and on a Cloud VM, so the
/// three scopes can never disagree about what a toggle means.
public enum RipgrepArguments {
    /// Generated directories skipped while "Use Exclude Settings and Ignore
    /// Files" is on. `.git` is always skipped because `--hidden` would
    /// otherwise search object storage.
    public static let defaultExcludedDirectories = ["node_modules", "dist", "build", "DerivedData"]

    /// The full argument vector after the `rg` executable name.
    public static func make(query: FileSearchQuery, rootPath: String) -> [String] {
        var arguments = [
            "--json",
            "--no-config",
            "--no-messages",
            "--hidden",
            query.isCaseSensitive ? "--case-sensitive" : "--ignore-case",
        ]
        if query.isRegex {
            // Falls back to PCRE2 for look-around and backreferences when the
            // installed ripgrep has it. Accepted by ripgrep 11 and later.
            arguments.append("--auto-hybrid-regex")
        } else {
            arguments.append("--fixed-strings")
        }
        if query.matchesWholeWord {
            arguments.append("--word-regexp")
        }
        if !query.usesIgnoreFiles {
            arguments.append("--no-ignore")
        }
        arguments += ["--glob", "!.git"]
        if query.usesIgnoreFiles {
            for directory in defaultExcludedDirectories {
                arguments += ["--glob", "!\(directory)"]
            }
        }
        for glob in FileSearchGlobPatterns.ripgrepGlobs(from: query.includePatterns) {
            arguments += ["--glob", glob]
        }
        for glob in FileSearchGlobPatterns.ripgrepGlobs(from: query.excludePatterns) {
            arguments += ["--glob", "!\(glob)"]
        }
        arguments += ["--", query.pattern, rootPath]
        return arguments
    }
}

/// VS Code's comma-separated glob fields, translated to ripgrep globs.
public enum FileSearchGlobPatterns {
    /// Splits on commas outside `{...}` alternations and trims each entry.
    public static func split(_ text: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var braceDepth = 0
        for character in text {
            switch character {
            case "{":
                braceDepth += 1
                current.append(character)
            case "}":
                braceDepth = max(0, braceDepth - 1)
                current.append(character)
            case "," where braceDepth == 0:
                entries.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        entries.append(current)
        return entries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Each entry becomes the glob itself plus, when its last component is a
    /// plain name, a variant that also matches everything inside a folder of
    /// that name. A name without a slash matches at any depth, like VS Code's
    /// `src` meaning `**/src/**`; a name with a slash stays anchored to the root.
    public static func ripgrepGlobs(from text: String) -> [String] {
        var globs: [String] = []
        for rawEntry in split(text) {
            var entry = rawEntry
            if entry.hasPrefix("!") { entry.removeFirst() }
            while entry.hasPrefix("./") { entry.removeFirst(2) }
            while entry.count > 1, entry.hasSuffix("/") { entry.removeLast() }
            guard !entry.isEmpty, entry != "." else { continue }
            globs.append(entry)
            let lastComponent = entry.split(separator: "/").last.map(String.init) ?? entry
            guard !lastComponent.contains(where: { "*?[{".contains($0) }) else { continue }
            if entry.contains("/") {
                globs.append("\(entry)/**")
            } else {
                globs.append("**/\(entry)/**")
            }
        }
        return globs
    }
}
