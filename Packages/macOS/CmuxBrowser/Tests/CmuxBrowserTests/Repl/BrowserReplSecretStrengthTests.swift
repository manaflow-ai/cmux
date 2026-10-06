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

    /// r20 native#3: the weak-value scan runs on the session's JavaScript
    /// thread, so a load past the (name, pattern) pairs the store can hold
    /// is refused before it, and the scan stops when the cell times out.
    @Test("secrets.load refuses more name and pattern pairs than the store holds before the weak scan")
    func tooManyEntriesAreRefusedBeforeTheScan() throws {
        let store = BrowserReplSecretStore()
        let limit = BrowserReplSecretStore.maximumSecrets * BrowserReplSecretStore.maximumDomains
        var group: [String: Any] = [:]
        for index in 0...limit { group["n\(index)"] = "x" }
        do {
            _ = try store.load(["example.com": group])
            Issue.record("a load of \(limit + 1) weak entries was taken")
        } catch let error as BrowserReplDriverError {
            #expect(error.code == "invalid")
            #expect(error.message.contains("\(limit)") && !error.message.contains("weak"), "\(error.message)")
        }
        #expect(store.describe().isEmpty)
    }

    @Test("secrets.load stops its weak-value scan when the cell is cancelled")
    func weakScanStopsOnCancellation() throws {
        let store = BrowserReplSecretStore()
        var groups: [String: Any] = [:]
        for index in 0..<64 { groups["d\(index).example.com"] = ["pw\(index)": "x"] }
        var asked = 0
        #expect(throws: CancellationError.self) {
            _ = try store.load(groups, isCancelled: {
                asked += 1
                return asked > 1
            })
        }
        #expect(store.describe().isEmpty)
    }
}
