import Foundation

/// Resolves which Kimi `config.toml` files cmux manages.
///
/// Kimi ships under two config layouts: Kimi Code CLI reads
/// `${KIMI_CODE_HOME:-~/.kimi-code}/config.toml`, and Kimi CLI 1.49 and earlier
/// read `${KIMI_SHARE_DIR:-~/.kimi}/config.toml`. cmux installs into the file
/// the installed binary reports, and keeps the other one intact rather than
/// deleting a block the other CLI still reads.
/// See https://github.com/manaflow-ai/cmux/issues/10255.
public struct KimiConfigLocationResolver {
    /// A well-known Kimi config directory and the variable that relocates it.
    public struct DirectorySpec: Equatable, Sendable {
        /// Environment variable that moves this installation's config directory.
        public let environmentOverride: String
        /// Directory name under the home directory when the variable is unset.
        public let homeRelativeDirectory: String

        /// Creates a directory spec.
        /// - Parameters:
        ///   - environmentOverride: Variable that relocates the directory.
        ///   - homeRelativeDirectory: Directory name relative to the home directory.
        public init(environmentOverride: String, homeRelativeDirectory: String) {
            self.environmentOverride = environmentOverride
            self.homeRelativeDirectory = homeRelativeDirectory
        }
    }

    /// The config file cmux installs into, plus the other files it manages.
    public struct Locations: Equatable, Sendable {
        /// Config file the installed Kimi CLI reads.
        public let active: URL
        /// Well-known config files belonging to the other installation.
        public let secondary: [URL]

        /// Creates a location set.
        /// - Parameters:
        ///   - active: Config file the installed Kimi CLI reads.
        ///   - secondary: Other well-known config files.
        public init(active: URL, secondary: [URL]) {
            self.active = active
            self.secondary = secondary
        }

        /// The active config file followed by every secondary one.
        public var all: [URL] { [active] + secondary }
    }

    /// Config file name shared by every Kimi installation.
    public static let configFileName = "config.toml"
    /// Home-relative config directory of the current Kimi Code CLI.
    public static let kimiCodeConfigDirectory = ".kimi-code"
    /// Home-relative config directory of Kimi CLI 1.49 and earlier.
    public static let kimiCLIConfigDirectory = ".kimi"
    /// Well-known config directories, most current first.
    public static let defaultDirectorySpecs = [
        DirectorySpec(
            environmentOverride: "KIMI_CODE_HOME",
            homeRelativeDirectory: kimiCodeConfigDirectory
        ),
        DirectorySpec(
            environmentOverride: "KIMI_SHARE_DIR",
            homeRelativeDirectory: kimiCLIConfigDirectory
        ),
    ]

    /// Characters that may follow a path in a report line without belonging to it.
    private static let pathDelimiters: Set<Character> = ["\"", "'", "`", ",", ";", ":", ")", "]", "}", ">"]

    private let environment: [String: String]
    private let fileManager: FileManager
    private let directorySpecs: [DirectorySpec]
    private let configFileName: String

    /// Creates a resolver.
    /// - Parameters:
    ///   - environment: Environment used for `HOME` and directory overrides.
    ///   - fileManager: File manager used for existence checks.
    ///   - directorySpecs: Well-known directories, most current first.
    ///   - configFileName: Config file name inside each directory.
    public init(
        environment: [String: String],
        fileManager: FileManager = .default,
        directorySpecs: [DirectorySpec] = KimiConfigLocationResolver.defaultDirectorySpecs,
        configFileName: String = KimiConfigLocationResolver.configFileName
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.directorySpecs = directorySpecs
        self.configFileName = configFileName
    }

    /// Every well-known config directory, most current first.
    /// - Returns: Candidate directories after applying environment overrides.
    public func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        return directorySpecs.map { spec in
            if let override = Self.nonEmptyValue(environment[spec.environmentOverride]) {
                return URL(
                    fileURLWithPath: NSString(string: override).expandingTildeInPath,
                    isDirectory: true
                )
            }
            return home.appendingPathComponent(spec.homeRelativeDirectory, isDirectory: true)
        }
    }

    /// Every well-known config file, most current first.
    /// - Returns: Candidate config file URLs.
    public func candidateConfigURLs() -> [URL] {
        candidateDirectories().map { directory in
            directory.appendingPathComponent(configFileName, isDirectory: false)
        }
    }

    /// The config directory to use when the installed binary reports none.
    ///
    /// Prefers a candidate that already holds a config file, then one whose
    /// directory exists, then the current Kimi Code CLI location.
    /// - Returns: The chosen config directory.
    public func fallbackConfigDirectory() -> URL {
        let candidates = candidateDirectories()
        if let configured = candidates.first(where: { directory in
            isRegularFile(directory.appendingPathComponent(configFileName, isDirectory: false))
        }) {
            return configured
        }
        if let installed = candidates.first(where: { isDirectory($0) }) {
            return installed
        }
        return candidates.first
            ?? homeDirectory().appendingPathComponent(
                Self.kimiCodeConfigDirectory,
                isDirectory: true
            )
    }

    /// The config file path a `kimi doctor` report names, when it names a usable one.
    ///
    /// Output that carries no absolute config path, or one whose parent
    /// directory does not exist, leaves the well-known locations in charge.
    /// - Parameter output: Combined standard output and error of `kimi doctor`.
    /// - Returns: The reported config file URL, or `nil`.
    public func reportedConfigURL(inDoctorOutput output: String) -> URL? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            if let url = reportedConfigURL(inDoctorOutputLine: String(line)) {
                return url
            }
        }
        return nil
    }

    /// Scans one report line for a config path.
    ///
    /// The report format is not specified, so each occurrence of the file name
    /// is extended leftwards to every earlier token-opening `/` or `~`, and the
    /// first candidate whose parent directory exists wins. That keeps a path
    /// containing spaces intact, which whitespace tokenization would split,
    /// while a label or prose before the path is rejected by the same directory
    /// check. Work is bounded by the length of a single line.
    private func reportedConfigURL(inDoctorOutputLine line: String) -> URL? {
        var nameSearchStart = line.startIndex
        while let nameRange = line.range(
            of: configFileName,
            range: nameSearchStart..<line.endIndex
        ) {
            nameSearchStart = nameRange.upperBound
            if nameRange.upperBound < line.endIndex {
                let following = line[nameRange.upperBound]
                guard following.isWhitespace || Self.pathDelimiters.contains(following) else {
                    continue
                }
            }

            for start in line.indices[line.startIndex..<nameRange.lowerBound]
            where startsPath(at: start, in: line) {
                if let url = usableConfigURL(String(line[start..<nameRange.upperBound])) {
                    return url
                }
            }
        }
        return nil
    }

    /// Whether a path could begin at this index: a `/` or `~` that opens a
    /// token rather than sitting inside one.
    private func startsPath(at index: String.Index, in line: String) -> Bool {
        let character = line[index]
        guard character == "/" || character == "~" else { return false }
        guard index > line.startIndex else { return true }
        let preceding = line[line.index(before: index)]
        return preceding.isWhitespace || Self.pathDelimiters.contains(preceding)
    }

    private func usableConfigURL(_ candidate: String) -> URL? {
        let expanded = NSString(string: candidate).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        guard url.lastPathComponent == configFileName,
              isDirectory(url.deletingLastPathComponent()) else { return nil }
        return url
    }

    /// The config files cmux manages for this installation.
    /// - Parameter reportedConfigURL: Path reported by the installed binary, if any.
    /// - Returns: The active config file and the remaining well-known ones.
    public func locations(reportedConfigURL: URL?) -> Locations {
        let active = reportedConfigURL
            ?? fallbackConfigDirectory().appendingPathComponent(configFileName, isDirectory: false)
        var seen: Set<URL> = [Self.canonical(active)]
        var secondary: [URL] = []
        for candidate in candidateConfigURLs() where seen.insert(Self.canonical(candidate)).inserted {
            secondary.append(candidate)
        }
        return Locations(active: active, secondary: secondary)
    }

    private func homeDirectory() -> URL {
        let home = Self.nonEmptyValue(environment["HOME"]) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Canonical identity of a config path.
    ///
    /// `resolvingSymlinksInPath()` alone leaves an intermediate symlink in
    /// place when the file itself does not exist yet, so the parent directory
    /// is resolved separately; otherwise a symlinked config directory would
    /// look like a second, distinct config file.
    private static func canonical(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath()
        return resolved
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(resolved.lastPathComponent, isDirectory: false)
            .standardizedFileURL
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
