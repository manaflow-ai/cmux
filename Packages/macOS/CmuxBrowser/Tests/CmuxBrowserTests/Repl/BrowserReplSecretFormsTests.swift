import Foundation
import Testing

@testable import CmuxBrowser

/// The secret store's redaction on hostile input: its cost and memory stay
/// bounded, and a value is found in the encodings a page or a server can
/// hand back (Base64 at any offset, JSON and HTML escapes).
@Suite("Browser REPL secret forms", .serialized)
struct BrowserReplSecretFormsTests {
    private static let longName = String(repeating: "n", count: 64)

    private func makeSession() throws -> BrowserReplSession {
        BrowserReplSession(
            id: "forms-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver()
        )
    }

    private func run(_ session: BrowserReplSession, _ code: String) async -> BrowserReplEvalResult? {
        await browserReplWithDeadline(seconds: 120) { await session.evaluate(code: code, timeout: .seconds(90)) }
    }

    /// A one-character secret with a 64-character name: each occurrence in
    /// a 1 MiB body grows 73 times when masked. The session must not build
    /// that (37 MiB here, gigabytes for the 64 MiB a fetch may return); it
    /// refuses with a clear error, and an output line says it was withheld.
    @Test("Masking cannot blow a bounded body up into a huge allocation")
    func maskingGrowthIsBounded() async throws {
        let body = Data(String(repeating: "Z,", count: 1 << 19).utf8)
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            (200, ["Content-Type": "text/plain"], body)
        }
        try await server.start()
        defer { server.stop() }
        let session = try makeSession()
        defer { session.close() }
        let result = await run(session, """
        secrets.set("\(Self.longName)", "Z", { domains: ["example.com"] });
        try {
          const text = await (await fetch("http://127.0.0.1:\(server.port)/big")).text();
          console.log("fetched", text.length);
        } catch (error) {
          console.log("refused", String(error.message).includes("limit"));
        }
        console.log("Z,".repeat(1 << 19));
        """)
        let lines = result?.lines.map(\.text) ?? []
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(lines.contains("refused true"), "\(lines.map { String($0.prefix(200)) })")
        #expect(lines.allSatisfy { $0.utf8.count < 9 << 20 }, "an output line grew past the limit")
        #expect(lines.contains { $0.contains("withheld") }, "\(lines.map { String($0.prefix(200)) })")
    }
}
