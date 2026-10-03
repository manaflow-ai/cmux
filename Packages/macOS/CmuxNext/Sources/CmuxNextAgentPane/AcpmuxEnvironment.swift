public import Foundation

/// Where this app's acpmux daemon lives and how to start it.
///
/// Same rule as `cmux acp` (cmux-tui `acp::tagged_home`), so the pane and
/// the CLI in its terminals reach one daemon: `ACPMUX_HOME` wins, else a
/// tagged dev build uses `~/.acpmux/tags/<slug>`, else `~/.acpmux`, shared
/// with a standalone `acpmux`. A daemon this app starts for a tag listens on
/// an ephemeral port, never the release daemon's 47811.
public nonisolated struct AcpmuxEnvironment: Sendable, Equatable {
    public var executable: URL
    public var home: URL
    public var socketPath: String
    /// Extra `acpmux daemon run` arguments.
    public var daemonArguments: [String]
    /// Variables the daemon and the status client must agree on.
    public var childEnvironment: [String: String]

    public var logPath: String { home.appendingPathComponent("daemon.log").path }

    /// Resolves the environment, or nil when no `acpmux` executable exists.
    /// `bundledBinDirectory` is the app's `Contents/Resources/bin`.
    public static func resolve(
        tag: String?,
        bundledBinDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AcpmuxEnvironment? {
        guard let executable = executableCandidates(bundledBinDirectory: bundledBinDirectory, environment: environment, userHome: userHome)
            .first(where: { isExecutable($0.path) }) else { return nil }
        let slug = tag.flatMap(tagSlug)
        let home: URL
        if let custom = environment["ACPMUX_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: custom, isDirectory: true)
        } else if let slug {
            home = userHome.appendingPathComponent(".acpmux/tags/\(slug)", isDirectory: true)
        } else {
            home = userHome.appendingPathComponent(".acpmux", isDirectory: true)
        }
        let socket = environment["ACPMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSocketPath(home: home, uid: uid)
        return AcpmuxEnvironment(
            executable: executable, home: home, socketPath: socket,
            daemonArguments: slug == nil ? [] : ["--listen", "127.0.0.1:0"],
            childEnvironment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket]
        )
    }

    /// The usual install directories, searched after `PATH`. The pane names
    /// them when acpmux is missing, so they are written as a user types them.
    static let installDirectories = ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Search order: the bundled binary, then `PATH`, then the usual install
    /// directories an app launched from Finder does not have on its `PATH`.
    static func executableCandidates(bundledBinDirectory: URL?, environment: [String: String], userHome: URL) -> [URL] {
        var directories: [String] = []
        if let bundled = bundledBinDirectory { directories.append(bundled.path) }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += installDirectories.map { directory in
            directory.hasPrefix("~/") ? userHome.appendingPathComponent(String(directory.dropFirst(2))).path : directory
        }
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("acpmux") }
    }

    /// Mirrors acpmux `config::socket_path()`: `<home>/acpmux.sock`, or
    /// `/tmp/acpmux-<uid>-<fnv1a64(home)>.sock` when that is too long for
    /// `sun_path` (96 bytes or more).
    static func defaultSocketPath(home: URL, uid: UInt32) -> String {
        let preferred = home.appendingPathComponent("acpmux.sock").path
        if preferred.utf8.count < 96 { return preferred }
        return "/tmp/acpmux-\(uid)-\(String(format: "%016llx", fnv1a64(home.path)))" + ".sock"
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// cmux-tui `acp::sanitize_tag`: lowercase, runs of anything outside
    /// `[a-z0-9]` become one `-`, no leading or trailing `-`; nil when empty.
    static func tagSlug(_ raw: String) -> String? {
        var slug = ""
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
