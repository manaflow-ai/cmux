import Foundation
import Testing

@testable import CmuxBrowser

/// A minimal runtime over the native host: `call(method, params)` returns a
/// promise of the driver's answer, `native` is the host itself.
private let historyRuntime = #"""
const pending = new Map();
let nextCall = 1;
globalThis.__cmuxHostOnResult = (id, error, result) => {
  const p = pending.get(id); pending.delete(id);
  if (!p) return;
  if (error) p.reject(Object.assign(new Error(JSON.parse(error).message), { code: JSON.parse(error).code }));
  else p.resolve(JSON.parse(result));
};
globalThis.__cmuxHostOnTimer = () => {};
globalThis.__cmuxHostOnEvent = () => {};
const call = (method, params) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  __cmuxNative.driverCall(id, method, JSON.stringify(params));
});
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) => new AsyncFunction("call", "native", code)(call, __cmuxNative);
"""#

/// Answers every call at once.
private final class AnsweringDriver: BrowserReplDriver, @unchecked Sendable {
    var capabilities: [String] { [] }
    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> { .success("null") }
    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}

@Suite("Browser REPL secret domain history", .serialized)
struct BrowserReplSecretDomainHistoryTests {
    /// r21 native finding 2: the session keeps the domains of every secret
    /// it typed (the policy may never reach past them). One set of domains
    /// is kept once however it is ordered or repeated, and the session
    /// keeps at most 1,024 distinct sets over its life: past that, typing a
    /// secret on a new set is refused with the limit, before anything is kept.
    @Test("A secret's domains are kept as one set however they are written, and at most 1,024 sets")
    func typedDomainSetsAreCanonicalAndBounded() async throws {
        let session = BrowserReplSession(
            id: "domain-history-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "history.js", source: historyRuntime)], agentScripts: []),
            driver: AnsweringDriver(),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 300) {
            await session.evaluate(code: """
            const a = "https://a.example.com";
            const x = (i) => `https://x${i}.example.com`;
            const policy = JSON.parse(native.policy("set", JSON.stringify({ allowed: [a] })));
            if (policy.error) throw new Error("policy: " + policy.error.message);
            const type = async (domains) => {
              const set = JSON.parse(native.secrets("set", JSON.stringify({ name: "s", value: "Zq8#tLw2!pXv9@Rm", domains })));
              if (set.error) return "set " + set.error.message;
              return call("input.insertText", { targetId: "t1", secret: "s" }).then(() => "ok", (e) => e.message);
            };
            const refused = [];
            // The same set, reordered and repeated: one entry.
            for (let i = 0; i < 64; i++) {
              const r = await type(i % 2 ? [x(1), a, a] : [a, ...Array(i % 7 + 1).fill(x(1))]);
              if (r !== "ok") refused.push("permutation " + i + ": " + r);
            }
            // 1,024 distinct sets in all.
            for (let i = 2; i <= 1023; i++) {
              const r = await type([a, x(i)]);
              if (r !== "ok") refused.push("set " + i + ": " + r);
            }
            const last = await type([x(2), a, x(1)]);
            if (last !== "ok") refused.push("set 1024: " + last);
            const repeat = await type([a, x(5)]);
            if (repeat !== "ok") refused.push("kept set: " + repeat);
            native.print("log", JSON.stringify({ refused, past: await type([a, x(1), x(3)]) }));
            """, timeout: .seconds(280))
        }
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        let text = result?.lines.last?.text ?? ""
        let outcome = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text.prefix(400))")
        let refused = outcome["refused"] as? [String] ?? []
        #expect(refused.isEmpty, "\(refused.prefix(3))")
        let past = outcome["past"] as? String ?? ""
        #expect(past.contains("REPL session limit") && past.contains("1024"), "a 1,025th set was kept: \(past)")
    }
}
