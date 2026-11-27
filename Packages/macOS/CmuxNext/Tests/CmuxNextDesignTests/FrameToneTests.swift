import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing

/// Subtle Tone's frame share (``FrameTone``) mirrors Rust's cmux-config `theme_file::frame_tone`: the same rungs and
/// step, and the same share and frame color for every sample theme in Rust's fixture, which this test has Rust write
/// to a temporary file (`cargo test -p cmux-config frame_tone::tests::writes_the_swift_fixture`), never committed.
/// Leo, 2026-11-23: "proper contrast that is only as contrasty as necessary".
struct FrameToneTests {
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
            .appendingPathComponent("frame-tone-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_FRAME_TONE_FIXTURE"] = out.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [environment["PATH"], "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }.joined(separator: ":")
        let cargo = Process()
        cargo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cargo.arguments = ["cargo", "test", "--quiet",
                           "--manifest-path", root.appendingPathComponent("cmux-tui/Cargo.toml").path,
                           "-p", "cmux-config", "--lib", "frame_tone::tests::writes_the_swift_fixture"]
        cargo.environment = environment
        cargo.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        cargo.standardError = errors
        try cargo.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        cargo.waitUntilExit()
        guard cargo.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let status = cargo.terminationStatus
            throw CargoFailed(description: "cargo could not write the frame-tone fixture (exit \(status)): "
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

    @Test func theRungsAreRusts() throws {
        let fixture = try Self.fixture()
        #expect(fixture["frameRung"] as? Double == FrameTone.frameRung)
        #expect(fixture["selectedRung"] as? Double == FrameTone.selectedRung)
        #expect(fixture["step"] as? Double == FrameTone.step)
    }

    @Test func everyThemeTakesRustsShare() throws {
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for item in cases {
            let name = try #require(item["theme"] as? String)
            let base = try Self.color(item["base"]), ink = try Self.color(item["ink"])
            let rust = try #require(item["share"] as? Double, "\(name)")
            let share = FrameTone.share(base: base, ink: ink)
            #expect(abs(share - rust) < 1e-4, "\(name): \(share) vs \(rust)")
            #expect(Self.near(FrameTone.washed(base, ink: ink, share: share), try Self.color(item["frame"])), "\(name)")
        }
    }

    @Test func aStateWashesToItsRungOverTheFrame() {
        let under = 0.05, wash = FrameTone.wash(rung: 0.08, over: under)
        #expect(abs(1 - (1 - under) * (1 - wash) - 0.08) < 1e-12)
        #expect(FrameTone.wash(rung: 0.04, over: under) == 0)
    }
}
