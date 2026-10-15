import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-lo9yf at the daemon spawn boundary (``AcpmuxHost``): with `labs.previewFeatures` on, the
/// acpmux daemon the app starts has `ACPMUX_OFFER_TOOLS=1`, so every local session gets the
/// cmux-sessions MCP server; off (the default) it does not. The flag is read at each daemon
/// start, so a toggle applies to the next daemon this app starts.
@Suite(.serialized)
struct AcpmuxOfferToolsTests {
    /// A short temp root with a stand-in `acpmux` that appends the `ACPMUX_OFFER_TOOLS` it was
    /// started with (or `unset`) to `launches`, then exits before it is ready.
    struct Fixture {
        let root: URL
        let environment: AcpmuxEnvironment
        var launches: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/aot-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let acpmux = bin.appendingPathComponent("acpmux")
            let script = "#!/bin/sh\nprintf '%s\\n' \"${ACPMUX_OFFER_TOOLS:-unset}\" >> '\(root.path)/launches'\nexit 1\n"
            try script.write(to: acpmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
                executableOverride: nil
            ))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The Labs switch as the app holds it: any thread reads it at a daemon start.
    nonisolated final class Labs: Sendable {
        let on: Mutex<Bool>
        init(_ on: Bool) { self.on = Mutex(on) }
        var isOn: Bool { on.withLock { $0 } }
    }

    @Test func previewFeaturesGiveTheDaemonTheSessionOfferTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        let host = AcpmuxHost(resolve: { environment }, offersSessionTools: { true })

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["1"], "acpmux started without ACPMUX_OFFER_TOOLS=1: \(fixture.launches)")
    }

    @Test func withoutPreviewFeaturesTheDaemonGetsNoOfferTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        let host = AcpmuxHost(resolve: { environment }, offersSessionTools: { false })

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["unset"], "acpmux started with ACPMUX_OFFER_TOOLS: \(fixture.launches)")
    }

    @Test func aToggleAppliesToTheNextDaemonStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let labs = Labs(false)
        let environment = fixture.environment
        let host = AcpmuxHost(resolve: { environment }, offersSessionTools: { labs.isOn })

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        labs.on.withLock { $0 = true }
        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: nil) }
        #expect(fixture.launches == ["unset", "1"], "the second daemon start missed the toggle: \(fixture.launches)")
    }
}
