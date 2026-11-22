import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import Testing

/// `appearance.twoTone` (``TwoTone``) mirrors Rust's cmux-config `theme_file::two_tone`: the same pairing table and
/// the same colors for every value and sample theme in Rust's fixture (`two_tone::fixture`), which this test has Rust
/// write to a temporary file (`cargo test -p cmux-config two_tone::tests::writes_the_swift_fixture`): the fixture is
/// generated where it is used, never committed.
/// Leo, 2026-11-19: "the two-tone ... that's just one of the toggles you can have ... what would actually look good
/// and not eyesore-ish".
struct TwoToneTests {
    struct CargoFailed: Error, CustomStringConvertible, Sendable {
        let description: String
    }

    /// Rust's fixture, written once per test process.
    private static let written: Result<Data, CargoFailed> = Result { try write() }
        .mapError { $0 as? CargoFailed ?? CargoFailed(description: "\($0)") }

    private static func write() throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-tone-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TWO_TONE_FIXTURE"] = out.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [environment["PATH"], "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }.joined(separator: ":")
        let cargo = Process()
        cargo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cargo.arguments = ["cargo", "test", "--quiet",
                           "--manifest-path", root.appendingPathComponent("cmux-tui/Cargo.toml").path,
                           "-p", "cmux-config", "--lib", "two_tone::tests::writes_the_swift_fixture"]
        cargo.environment = environment
        cargo.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        cargo.standardError = errors
        try cargo.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        cargo.waitUntilExit()
        guard cargo.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let status = cargo.terminationStatus
            throw CargoFailed(description: "cargo could not write the two-tone fixture (exit \(status)): "
                + String(decoding: stderr.suffix(4000), as: UTF8.self))
        }
        return try Data(contentsOf: out)
    }

    private static func fixture() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: written.get()) as? [String: Any])
    }

    private static func color(_ text: Any?) throws -> ThemeRGB {
        try #require((text as? String).flatMap(ThemeRGB.init(cssHex:)), "\(String(describing: text))")
    }

    /// Two colors within one 8-bit step per channel (libm may round the last bit differently).
    private static func near(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) <= 1.5 / 255
    }

    @Test func theValuesAreRusts() throws {
        let values = try #require(try Self.fixture()["values"] as? [String])
        #expect(values == TwoTone.allCases.map(\.rawValue))
    }

    @Test func thePairingTableIsRusts() throws {
        let pairings = try #require(try Self.fixture()["pairings"] as? [[String: Any]])
        for pairing in pairings {
            let id = try #require(pairing["id"] as? String)
            let variants = try #require(TwoTone(rawValue: id)?.variants, "\(id)")
            for (side, variant) in [("dark", variants.dark), ("light", variants.light)] {
                let colors = try #require(pairing[side] as? [String: String])
                #expect(try Self.color(colors["chrome"]) == ThemeRGB(hex: variant.chrome), "\(id) \(side)")
                #expect(try Self.color(colors["content"]) == ThemeRGB(hex: variant.content), "\(id) \(side)")
                #expect(try Self.color(colors["accent"]) == ThemeRGB(hex: variant.accent), "\(id) \(side)")
            }
        }
    }

    @Test func everyCaseResolvesAsRustDoes() throws {
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let value = try #require((item["value"] as? String).flatMap(TwoTone.init), "\(item)")
            let tones = try #require(value.tones(background: try Self.color(item["background"]),
                                                 foreground: try Self.color(item["foreground"]),
                                                 accent: try Self.color(item["accent"]),
                                                 dark: try #require(item["dark"] as? Bool)))
            let label = "\(item["theme"] ?? "") \(value)"
            #expect(Self.near(tones.chrome, try Self.color(item["chrome"])), "\(label) chrome \(tones.chrome)")
            #expect(Self.near(tones.accent, try Self.color(item["toneAccent"])), "\(label) accent \(tones.accent)")
            if item["content"] is NSNull {
                #expect(tones.content == nil, "\(label)")
            } else {
                let content = try #require(tones.content, "\(label)")
                #expect(Self.near(content, try Self.color(item["content"])), "\(label) content \(content)")
            }
        }
    }

    @Test func offPaintsNothing() {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        for kind in SurfaceKind.allCases { #expect(TwoTone.off.color(for: kind, tokens: tokens) == nil) }
        #expect(SurfaceBackgrounds(twoTone: .off).fill(for: .sidebar, tokens: tokens) == nil)
        #expect(!SurfaceBackgrounds(twoTone: .auto).overridesTerminal)
    }

    /// The chrome takes tone A and the content tone B; an explicit surface color still wins.
    @Test func surfacesTakeTheirTonesAndAnExplicitColorWins() throws {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        let backgrounds = SurfaceBackgrounds(twoTone: .inkSakura)
        let sidebar = try #require(backgrounds.fill(for: .sidebar, tokens: tokens, windowTint: 1))
        let tabBar = try #require(backgrounds.fill(for: .tabBar, tokens: tokens, windowTint: 1))
        let terminal = try #require(backgrounds.fill(for: .terminal, tokens: tokens, windowTint: 1))
        #expect(sidebar == tabBar)
        #expect(sidebar.withAlpha(1) != terminal.withAlpha(1))
        #expect(backgrounds.overridesTerminal)
        #expect(backgrounds.fill(for: .settings, tokens: tokens) == nil)
        let red = ThemeRGB(hex: 0xFF0000)
        let explicit = SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(color: red)], twoTone: .inkSakura)
        #expect(explicit.fill(for: .sidebar, tokens: tokens, windowTint: 1)?.withAlpha(1) == red)
        // `auto` keeps the content the theme's own.
        #expect(SurfaceBackgrounds(twoTone: .auto).fill(for: .terminal, tokens: tokens) == nil)
    }
}
