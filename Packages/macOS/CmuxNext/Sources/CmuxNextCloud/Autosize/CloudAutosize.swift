public import Foundation

/// What a chat's Cloud machine is sized for: `POST /api/vm`'s `autosize.taskKind`
/// (web/services/vms/autosize.ts). A chat is light work whatever the repo; a build or a test
/// gets the fleet's measured grant for the repo's toolchain.
public enum CloudTaskKind: String, Sendable, Equatable, CaseIterable {
    case chat, build, test

    /// The kind the chat's own words make obvious, else ``chat``. The rule is kept simple on
    /// purpose, and it is the whole rule: a word that names testing (``testWords``) makes it
    /// ``test``; else a word that names building (``buildWords``) makes it ``build``; anything
    /// else is ``chat``. Whole words only, so "latest" or "rebuilding trust" name no task, and
    /// testing wins over building because a test run builds first.
    ///
    /// - Parameter text: The chat's prompt or title; nil is a chat.
    public static func inferred(from text: String?) -> CloudTaskKind {
        guard let text, !text.isEmpty else { return .chat }
        let words = Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
        if !words.isDisjoint(with: testWords) { return .test }
        if !words.isDisjoint(with: buildWords) { return .build }
        return .chat
    }

    /// The words that make a chat a test run.
    public static let testWords: Set<String> = ["test", "tests", "testing", "e2e", "xctest", "pytest", "vitest", "jest"]
    /// The words that make a chat a build.
    public static let buildWords: Set<String> = ["build", "builds", "building", "rebuild", "compile", "compiles", "compiling"]
}

/// `POST /api/vm`'s `autosize`: what the server's picker needs to choose the machine's shape
/// with no prompt (the repo's identity, size and root files, and the task kind).
public struct CloudAutosizeRequest: Equatable, Sendable {
    public var taskKind: CloudTaskKind
    /// `host/owner/name`, lower-cased: the key the server files measured runs under. Nil outside
    /// git, or with no remote it can name.
    public var repoKey: String?
    /// The repository's git objects in MiB (`git count-objects`); nil outside git.
    public var repoSizeMb: Int?
    /// The names at the working copy's top (`Package.swift`, `Cargo.toml`, `package.json`, …),
    /// which tell the server the toolchain.
    public var rootFiles: [String]

    public init(taskKind: CloudTaskKind = .chat, repoKey: String? = nil, repoSizeMb: Int? = nil, rootFiles: [String] = []) {
        self.taskKind = taskKind
        self.repoKey = repoKey
        self.repoSizeMb = repoSizeMb
        self.rootFiles = rootFiles
    }

    /// The server's limits (autosize.ts `parseAutosizeRepo`): at most 500 names of at most 255
    /// characters, a key of at most 200 characters.
    public static let maxRootFiles = 500
    public static let maxNameLength = 255
    public static let maxKeyLength = 200

    /// The JSON object the create sends.
    public var body: [String: any Sendable] {
        var repo: [String: any Sendable] = [:]
        if let repoKey { repo["key"] = repoKey }
        if let repoSizeMb { repo["sizeMb"] = repoSizeMb }
        if !rootFiles.isEmpty { repo["rootFiles"] = rootFiles }
        var body: [String: any Sendable] = ["taskKind": taskKind.rawValue]
        if !repo.isEmpty { body["repo"] = repo }
        return body
    }
}

/// The create answer's `sizePick` (`POST /api/vm` with `autosize`): the shape the server chose
/// and one line on why, e.g. "4 vCPU · 16 GB, picked from 3 earlier runs". Its fields are the
/// hand-off's `size` (`POST /v1/handoffs {sessionId, machine, size}`), as ``handoffSize``.
public struct CloudSizePick: Equatable, Hashable, Sendable, Codable {
    public var vcpus: Int
    public var memoryGb: Double
    /// The ladder row's name (`sm`, `md`, `lg`, …).
    public var pick: String
    /// The one line the chat shows.
    public var reason: String

    public init(vcpus: Int, memoryGb: Double, pick: String, reason: String) {
        self.vcpus = vcpus
        self.memoryGb = memoryGb
        self.pick = pick
        self.reason = reason
    }

    /// `POST /v1/handoffs`'s `size` object.
    public var handoffSize: [String: any Sendable] { ["vcpus": vcpus, "memoryGb": memoryGb, "pick": pick, "reason": reason] }
}
