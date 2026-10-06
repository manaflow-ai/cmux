import Foundation
import Testing

@testable import CmuxBrowser

/// Owner decision 2026-10-06: `secrets.load` refuses a weak value (shorter
/// than 8 characters, or one of a small list of common passwords), since a
/// value masked by comparison can be confirmed by printing guesses. The
/// whole load is refused, naming the weak secrets and never their values;
/// `{ allowWeak: true }` loads them anyway.
@Suite("Browser REPL secrets.load and weak values")
struct BrowserReplSecretStrengthTests {
    @Test("secrets.load refuses a short or common value unless allowWeak is given")
    func weakValuesAreRefusedUnlessAllowed() async throws {
        let session = BrowserReplSession(
            id: "strength-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: try browserReplRepositoryBundle(),
            driver: RecordingReplDriver()
        )
        defer { session.close() }

        let result = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: """
            const attempt = (label, run) => { try { run(); console.log(label + ": loaded"); } catch (e) { console.log(label + ": " + e.message); } };
            attempt("short", () => secrets.load({ "example.com": { pw: "hunter2" } }));
            attempt("common", () => secrets.load({ "example.com": { pw: "Password1" } }));
            attempt("mixed", () => secrets.load({ "example.com": { key: "Zx9-strong-VALUE-77", pin: "4271" } }));
            console.log("held: " + JSON.stringify(secrets.list().map((s) => s.name)));
            attempt("allowed", () => secrets.load({ "example.com": { pw: "hunter2" } }, { allowWeak: true }));
            attempt("strong", () => secrets.load({ "example.com": { key: "Zx9-strong-VALUE-77" } }));
            console.log("held: " + JSON.stringify(secrets.list().map((s) => s.name).sort()));
            """, timeout: .seconds(20))
        }

        #expect(result?.error == nil, "\(String(describing: result?.error))")
        let lines = result?.lines.map(\.text) ?? []
        let byLabel = Dictionary(lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        for label in ["short", "common", "mixed"] {
            let outcome = byLabel[label] ?? ""
            #expect(outcome != "loaded", "\(label) was loaded: \(lines)")
            #expect(outcome.contains("allowWeak"), "\(label): \(outcome)")
        }
        #expect(byLabel["mixed"]?.contains("pin") == true, "\(lines)")
        #expect(byLabel["mixed"]?.contains("4271") == false, "the refusal shows the value: \(lines)")
        #expect(lines.contains("held: []"), "a refused load registered something: \(lines)")
        #expect(byLabel["allowed"] == "loaded", "\(lines)")
        #expect(byLabel["strong"] == "loaded", "\(lines)")
        #expect(lines.last == #"held: ["key","pw"]"#, "\(lines)")
    }
}
