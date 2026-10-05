import Foundation
import Testing
@testable import CmuxNextTerminal

/// The shared vectors for the user's Ghostty `shell-integration-features`
/// and `cursor-style-blink` (schemas/ghostty-shell-features/vectors.json)
/// hold what libghostty resolves for each syntax form and include rule. The
/// cmux-tui daemon's own reader replays the same file
/// (decision DAEMON-SHELL-FEATURES-FROM-GHOSTTY-FILES), so this test keeps
/// both equal to Ghostty.
@MainActor @Suite(.serialized) struct GhosttyShellFeaturesVectorTests {
    /// libghostty needs `ghostty_init` (the shared runtime) before configs.
    init() { _ = GhosttyRuntime.shared }

    struct Case: Decodable {
        var name: String
        var files: [String: String]
        var features: [String]
        var cursorBlink: Bool?

        enum CodingKeys: String, CodingKey {
            case name, files, features
            case cursorBlink = "cursor_blink"
        }
    }

    struct Vectors: Decodable {
        var cases: [Case]
    }

    /// Ghostty's `ShellIntegrationFeatures` bits, in packed-struct order.
    static let bits: [(String, UInt32)] = [
        ("cursor", 1 << 0), ("sudo", 1 << 1), ("title", 1 << 2), ("ssh-env", 1 << 3), ("ssh-terminfo", 1 << 4), ("path", 1 << 5),
    ]

    static func vectors() throws -> [Case] {
        // Tests/CmuxNextTerminalTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appending(path: "schemas/ghostty-shell-features/vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data).cases
    }

    @Test func libghosttyResolvesEveryVector() throws {
        let cases = try Self.vectors()
        #expect(cases.count >= 20)
        for vector in cases {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "ghostty-shell-features-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            for (name, text) in vector.files {
                let file = directory.appending(path: name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            let settings = try #require(GhosttyRuntime.shellIntegrationSettings(configFile: directory.appending(path: "config").path),
                                        "\(vector.name)")
            let enabled = Self.bits.filter { settings.features & $0.1 != 0 }.map(\.0)
            #expect(Set(enabled) == Set(vector.features), "\(vector.name)")
            #expect(settings.cursorBlink == vector.cursorBlink, "\(vector.name)")
        }
    }
}
