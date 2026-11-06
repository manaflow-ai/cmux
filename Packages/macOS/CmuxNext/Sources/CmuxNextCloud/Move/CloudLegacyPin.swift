public import Foundation

/// The app's pinned Linux build for a Cloud machine too old to update in place (the legacy exec
/// update, `CloudLegacyMachineUpdate` in CmuxNextApp): the commit the machine's daemon reports
/// once it runs it, and the binary's SHA-256. Both reach a shell on the machine, so anything that
/// is not plain lowercase hex is refused.
///
/// The pin is the app bundle's own manifest (`Resources/bin/cmux-tui-ssh/manifest.json`, the one
/// `cmux link machine update` reads). A DEV build ships none; its `cmux` client then names the pin
/// itself (`cmux link machine pin`, cmux-tui `link/machine_pin.rs`): the published manifest of the
/// build's own commit or, for a tree-mode bundle, of the commit that published its cmux-tui tree,
/// the same pin `cmux link machine update` installs.
public struct CloudLegacyPin: Sendable, Equatable {
    /// The build's commit: the `build` its daemon reports.
    public var commit: String
    /// SHA-256 of the binary.
    public var sha256: String

    public init(commit: String, sha256: String) {
        self.commit = commit
        self.sha256 = sha256
    }

    /// The Rust target of every Cloud machine's binary (x86_64, the release's static build).
    public static let target = "x86_64-unknown-linux-musl"

    /// The pin of the legacy update to `build`. With a bundled manifest, only when it is that
    /// build's (a manifest of another build is not this app's). Without one (a DEV build), the pin
    /// `ask` (`cmux link machine pin`'s output) names: the CLI resolves this client's own commit or
    /// cmux-tui tree, whose publishing commit may be an earlier one than `build`. Nil otherwise.
    public static func pin(for build: String, besideCLI cli: URL, ask: () async -> Data?) async -> CloudLegacyPin? {
        guard let bundled = pin(besideCLI: cli) else { return await ask().flatMap(pin(answer:)) }
        let build = build.lowercased()
        return build.count >= 7 && (bundled.commit.hasPrefix(build) || build.hasPrefix(bundled.commit)) ? bundled : nil
    }

    /// The pin in the manifest beside the app's `cmux` client, nil when the app ships none (DEV
    /// builds) or it is malformed.
    public static func pin(besideCLI cli: URL) -> CloudLegacyPin? {
        let manifest = cli.deletingLastPathComponent().appendingPathComponent("cmux-tui-ssh/manifest.json")
        return (try? Data(contentsOf: manifest)).flatMap(pin(manifest:))
    }

    /// The pin in a `cmux-tui-ssh/manifest.json`: `commit` (40 hex) and the x86_64 Linux binary's
    /// digest (64 hex).
    public static func pin(manifest: Data) -> CloudLegacyPin? {
        struct Manifest: Decodable {
            var commit: String
            var binaries: [String: String]
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifest),
              let sha256 = manifest.binaries["cmux-tui-\(target)"]?.lowercased(),
              isHex(manifest.commit.lowercased(), count: 40), isHex(sha256, count: 64) else { return nil }
        return CloudLegacyPin(commit: manifest.commit.lowercased(), sha256: sha256)
    }

    /// The pin in `cmux link machine pin`'s output: its last line,
    /// `{"ok":true,"commit":..,"sha256":..,"target":"x86_64-unknown-linux-musl"}`. Any other answer
    /// (`ok` false, another target, a value that is not lowercase hex) is none.
    public static func pin(answer: Data) -> CloudLegacyPin? {
        struct Answer: Decodable {
            var ok: Bool
            var commit: String?
            var sha256: String?
            var target: String?
        }
        let line = String(decoding: answer, as: UTF8.self).split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) })
        guard let line, let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)), answer.ok, answer.target == target,
              let commit = answer.commit, let sha256 = answer.sha256, isHex(commit, count: 40), isHex(sha256, count: 64) else { return nil }
        return CloudLegacyPin(commit: commit, sha256: sha256)
    }

    /// `count` lowercase hex digits.
    public static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
