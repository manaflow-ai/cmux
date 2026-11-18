public import Foundation

/// The app's pinned Linux build for a Cloud machine too old to update in place (the legacy exec update,
/// `CloudLegacyMachineUpdate` in CmuxNextApp): the commit its daemon reports once it runs it, and the binary's
/// SHA-256. Rust reads the bundle's manifest or the CLI's answer and refuses anything that is not plain
/// lowercase hex (`moves::pin`); this reads the manifest file and asks the CLI.
public struct CloudLegacyPin: Sendable, Equatable, Codable {
    /// The build's commit: the `build` its daemon reports.
    public var commit: String
    /// SHA-256 of the binary.
    public var sha256: String

    public init(commit: String, sha256: String) {
        self.commit = commit
        self.sha256 = sha256
    }

    private struct Request: Encodable { var manifest: String?, answer: String?, build: String? }
    private struct Reply: Decodable { var pin: CloudLegacyPin?, bundled: Bool, target: String }

    /// The Rust target of every Cloud machine's binary (Rust's `pin::TARGET`, the release's static x86_64 build).
    public static let target: String = ask()?.target ?? "x86_64-unknown-linux-musl"

    private static func ask(manifest: Data? = nil, answer: Data? = nil, build: String? = nil) -> Reply? {
        let text = { (data: Data?) in data.map { String(decoding: $0, as: UTF8.self) } }
        return CloudMoveCore().call("pin", Request(manifest: text(manifest), answer: text(answer), build: build), as: Reply.self)
    }

    /// The pin of the legacy update to `build`: the bundled manifest's when it is that build's, else (a DEV build
    /// ships none) the pin `ask` (`cmux link machine pin`'s output) names. Nil otherwise.
    public static func pin(for build: String, besideCLI cli: URL, ask: () async -> Data?) async -> CloudLegacyPin? {
        let manifest = try? Data(contentsOf: manifestURL(besideCLI: cli))
        if let reply = Self.ask(manifest: manifest, build: build), reply.bundled { return reply.pin }
        return await ask().flatMap(pin(answer:))
    }

    /// The pin in the manifest beside the app's `cmux` client, nil when the app ships none (DEV builds) or it is malformed.
    public static func pin(besideCLI cli: URL) -> CloudLegacyPin? {
        (try? Data(contentsOf: manifestURL(besideCLI: cli))).flatMap(pin(manifest:))
    }

    /// The pin in a `cmux-tui-ssh/manifest.json`.
    public static func pin(manifest: Data) -> CloudLegacyPin? { ask(manifest: manifest)?.pin }

    /// The pin in `cmux link machine pin`'s output.
    public static func pin(answer: Data) -> CloudLegacyPin? { ask(answer: answer)?.pin }

    /// `count` lowercase hex digits.
    public static func isHex(_ text: String, count: Int) -> Bool {
        struct Request: Encodable { var text: String, count: Int }
        struct Reply: Decodable { var hex: Bool }
        return CloudMoveCore().call("is_hex", Request(text: text, count: count), as: Reply.self)?.hex ?? false
    }

    private static func manifestURL(besideCLI cli: URL) -> URL {
        cli.deletingLastPathComponent().appendingPathComponent("cmux-tui-ssh/manifest.json")
    }
}

/// The app's update of a Cloud machine too old to update in place reads how its run ended from what the exec
/// printed; Rust maps the guest script's result line to a `link machine update` answer (`ExecRun`).
public nonisolated extension CloudExecResult {
    private struct Legacy: Decodable { var answer: CloudMoveCLI.Answer, lastLine: String, failureDetail: String }

    private func legacy(_ commit: String = "") -> Legacy {
        struct Request: Encodable { var exitCode: Int, stdout: String, stderr: String, commit: String }
        return CloudMoveCore().call("legacy_update", Request(exitCode: exitCode, stdout: stdout, stderr: stderr, commit: commit), as: Legacy.self)
            ?? Legacy(answer: CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unresolved"), lastLine: "", failureDetail: "")
    }

    /// The last line of stdout: the guest script's result line.
    var lastLine: String { legacy().lastLine }

    /// What a failure says: the result line, else the end of stderr.
    var failureDetail: String { legacy().failureDetail }

    /// The guest script's result line as a `link machine update` answer for the pinned build `commit`.
    func legacyUpdateAnswer(pinned commit: String) -> CloudMoveCLI.Answer { legacy(commit).answer }
}
