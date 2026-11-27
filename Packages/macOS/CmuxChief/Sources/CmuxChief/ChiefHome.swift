public import Foundation

/// The directory that holds one build's Chief: its conversations, blobs,
/// memory and state.
///
/// Every build has its own Chief home, keyed by its bundle id, so a DEV,
/// NIGHTLY and release build never share conversations or memory. Resolution,
/// first match wins:
///
/// 1. `CMUX_CHIEF_HOME`: that directory (tests and preflights).
/// 2. `~/.cmux/chief/<bundle id>`, the bundle id reduced to a path component.
/// 3. `~/.cmux/chief/default` for a process without a bundle id.
///
/// ```swift
/// let home = ChiefHome.resolve()
/// try home.createDirectories()
/// ```
public struct ChiefHome: Sendable, Equatable {
    /// The home's root directory.
    public let root: URL

    /// The environment variable that names an explicit home.
    public static let environmentKey = "CMUX_CHIEF_HOME"

    /// Creates a home at an explicit root.
    ///
    /// - Parameter root: The directory that holds the Chief's files.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// One JSON Lines file per conversation (`<conversation id>.jsonl`).
    public var conversationsDirectory: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    /// Attachment bytes by SHA-256 (`<hash>/data.<ext>`).
    public var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    /// The Chief's long-term memory, owned by the brain.
    public var memoryDirectory: URL { root.appendingPathComponent("memory", isDirectory: true) }
    /// Host state (locks, markers) owned by the app.
    public var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// Creates the root and every subdirectory.
    ///
    /// - Throws: The file system error when a directory cannot be created.
    public func createDirectories() throws {
        for directory in [conversationsDirectory, blobsDirectory, memoryDirectory, stateDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Resolves this process's Chief home.
    ///
    /// - Parameters:
    ///   - environment: The process environment; `CMUX_CHIEF_HOME` wins when set and non-empty.
    ///   - userHome: The user's home directory, under which `.cmux/chief` lives.
    ///   - bundleID: The build's bundle id; nil or empty resolves `default`.
    /// - Returns: The resolved home.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                               bundleID: String? = Bundle.main.bundleIdentifier) -> ChiefHome {
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            return ChiefHome(root: URL(fileURLWithPath: explicit, isDirectory: true))
        }
        let base = userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
        let name = bundleID.flatMap(component(of:)) ?? "default"
        return ChiefHome(root: base.appendingPathComponent(name, isDirectory: true))
    }

    /// A path component: runs of anything outside `[A-Za-z0-9._]` become one
    /// `-`; nil when nothing is left.
    static func component(of raw: String) -> String? {
        var out = ""
        for character in raw {
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
                out.append(character)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? nil : trimmed
    }
}
