public import Foundation

/// The `Host` aliases of one OpenSSH config file: the names a person types after `ssh`, which
/// New Remote Group offers as hosts (remote-groups-DESIGN.md slice E).
///
/// Patterns (`*`, `?`, `!`) are not hosts and are skipped, as are `Match` blocks; each alias is
/// kept once, first spelling wins (OpenSSH matches host names case-insensitively). `Include`
/// arguments are returned unexpanded for the caller to read (``includes``).
///
/// ```swift
/// let hosts = SSHConfigHosts(text: try String(contentsOf: configURL, encoding: .utf8))
/// hosts.aliases // ["mini", "linux-vm"]
/// ```
public nonisolated struct SSHConfigHosts: Equatable, Sendable {
    /// The aliases in file order.
    public let aliases: [String]
    /// The `Include` arguments in file order (`~/.ssh/config.d/*`, relative paths are under `~/.ssh`).
    public let includes: [String]

    /// Parses a config file's text.
    /// - Parameter text: the file's contents.
    public init(text: String) {
        var aliases: [String] = []
        var seen: Set<String> = []
        var includes: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, rest) = keywordAndArguments(line)
            let words = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch keyword.lowercased() {
            case "host":
                for word in words where !word.contains(where: { "*?!".contains($0) }) {
                    if seen.insert(word.lowercased()).inserted { aliases.append(word) }
                }
            case "include":
                includes.append(contentsOf: words)
            default:
                continue
            }
        }
        self.aliases = aliases
        self.includes = includes
    }
}

public nonisolated extension SSHConfigHosts {
    /// The aliases of `config` in `directory` and of the files it `Include`s (one level, globs
    /// expanded; `~` is home, a relative path is under `directory`, as OpenSSH reads it). Blocking
    /// file reads through `read`: call it on a blocking lane (`BackgroundWork.run(_:mayBlock: .files)`).
    /// - Parameters:
    ///   - directory: the folder of `config` (`~/.ssh`).
    ///   - home: the home folder `~` names.
    ///   - read: a file's text, nil when it cannot be read (the app passes `String(blockingContentsOfFile:encoding:)`).
    /// - Returns: the aliases in file order; empty when there is no config.
    static func aliases(in directory: URL, home: URL, read: (String) -> String?) -> [String] {
        guard let text = read(directory.appending(path: "config").path) else { return [] }
        let top = SSHConfigHosts(text: text)
        var aliases = top.aliases
        for pattern in top.includes {
            for path in expand(pattern, under: directory, home: home) {
                guard let included = read(path) else { continue }
                aliases += SSHConfigHosts(text: included).aliases
            }
        }
        return aliases
    }
}

/// An `Include` argument's files.
private nonisolated func expand(_ pattern: String, under directory: URL, home: URL) -> [String] {
    let path = pattern.hasPrefix("~/") ? home.appending(path: String(pattern.dropFirst(2))).path
        : pattern.hasPrefix("/") ? pattern : directory.appending(path: pattern).path
    var matches = glob_t()
    defer { globfree(&matches) }
    guard glob(path, 0, nil, &matches) == 0 else { return [] }
    return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
}

/// A config line's keyword and the rest: `Host a b`, `Host=a b` and `Host\ta` all name `Host`.
private nonisolated func keywordAndArguments(_ line: String) -> (String, String) {
    guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (line, "") }
    var rest = line[end...].drop(while: { $0 == " " || $0 == "\t" })
    if rest.first == "=" { rest = rest.dropFirst() }
    return (String(line[..<end]), rest.trimmingCharacters(in: .whitespaces))
}
