import Foundation
import Testing

@testable import CmuxBrowser

/// Answers `tabs.list` and echoes other calls, recording what it received.
final class RecordingReplDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: BrowserReplDriverEventSink?
    private(set) var calls: [String] = []

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        lock.withLock { calls.append(method) }
        switch method {
        case "tabs.list":
            return .success(#"[{"targetId":"t1","title":"Fixture","url":"about:blank","active":true}]"#)
        case "tab.missing":
            return .failure(BrowserReplDriverError(code: "not_found", message: "no such tab"))
        default:
            return .success(paramsJSON)
        }
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {
        lock.withLock { sink = eventSink }
    }

    func detach() {
        lock.withLock { sink = nil }
    }

    func emit(_ name: String, _ payload: String) {
        let sink = lock.withLock { self.sink }
        sink?(name, payload)
    }
}

/// A minimal runtime that exercises every native host entry point.
private let stubRuntime = #"""
const pending = new Map();
let nextCall = 1;
const timers = new Map();
let nextTimer = 1;
globalThis.__cmuxHostOnResult = (id, error, result) => {
  const p = pending.get(id); pending.delete(id);
  if (error) p.reject(Object.assign(new Error(JSON.parse(error).message), { code: JSON.parse(error).code }));
  else p.resolve(JSON.parse(result));
};
globalThis.__cmuxHostOnTimer = (id) => { const t = timers.get(id); if (t) { timers.delete(id); t(); } };
globalThis.__cmuxHostOnEvent = (name, payload) => { globalThis.lastEvent = [name, JSON.parse(payload)]; };
const call = (method, params) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  __cmuxNative.driverCall(id, method, JSON.stringify(params ?? {}));
});
const sleep = (ms) => new Promise((r) => { const id = nextTimer++; timers.set(id, r); __cmuxNative.setTimer(id, ms, false); });
const fs = (op, args) => { const r = JSON.parse(__cmuxNative.fs(op, JSON.stringify(args))); if (r.error) throw new Error(r.error.code); return r.ok; };
const console = { log: (...a) => __cmuxNative.print("log", a.map(String).join(" ")), error: (...a) => __cmuxNative.print("error", a.map(String).join(" ")) };
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (...args) =>
  new AsyncFunction("console", "call", "sleep", "fs", "evalArity", "native", "evalOptions", args[0])(console, call, sleep, fs, args.length, __cmuxNative, args[1]);
"""#

@Suite("Browser REPL session")
struct BrowserReplSessionTests {
    private func makeSession(
        driver: RecordingReplDriver,
        cwd: String? = nil,
        temporaryDirectory: String? = nil
    ) -> BrowserReplSession {
        BrowserReplSession(
            id: "test-\(UUID().uuidString)",
            cwd: cwd ?? FileManager.default.temporaryDirectory.path,
            bundle: BrowserReplRuntimeBundle(
                replScripts: [.init(name: "stub.js", source: stubRuntime)],
                agentScripts: []
            ),
            driver: driver,
            temporaryDirectory: temporaryDirectory
        )
    }

    @Test("Console output, driver calls and timers complete inside one evaluation")
    func evaluationRoundTrip() async {
        let driver = RecordingReplDriver()
        let session = makeSession(driver: driver)
        defer { session.close() }

        let result = await session.evaluate(
            code: """
            const tabs = await call("tabs.list");
            console.log(evalArity, tabs[0].targetId);
            await sleep(5);
            console.error("after", (await call("tab.info", { targetId: "t1" })).targetId);
            """
        )

        #expect(result.error == nil)
        #expect(result.lines == [
            BrowserReplOutputLine(level: "log", text: "2 t1"),
            BrowserReplOutputLine(level: "error", text: "after t1"),
        ])
        #expect(driver.calls == ["tabs.list", "tab.info"])
    }

    @Test("An output cap reaches the runtime as its options argument")
    func maxOutputOption() async {
        let session = makeSession(driver: RecordingReplDriver())
        defer { session.close() }

        // The options always carry the evaluation's id, so a timeout cancels only that cell.
        let capped = await session.evaluate(code: "console.log(evalArity, evalOptions);", maxOutput: 1234)
        #expect(capped.lines == [BrowserReplOutputLine(level: "log", text: #"2 {"evalId":1,"maxOutput":1234}"#)])
        let unlimited = await session.evaluate(code: "console.log(evalOptions);", maxOutput: 0)
        #expect(unlimited.lines == [BrowserReplOutputLine(level: "log", text: #"{"evalId":2,"maxOutput":0}"#)])
        let runtimeDefault = await session.evaluate(code: "console.log(evalOptions);")
        #expect(runtimeDefault.lines == [BrowserReplOutputLine(level: "log", text: #"{"evalId":3}"#)])
    }

    @Test("Uncaught errors and driver errors are reported with the runtime's formatter")
    func uncaughtError() async {
        let driver = RecordingReplDriver()
        let session = makeSession(driver: driver)
        defer { session.close() }

        let thrown = await session.evaluate(code: "console.log('before'); throw new TypeError('boom');")
        #expect(thrown.error == "TypeError: boom")
        #expect(thrown.lines == [BrowserReplOutputLine(level: "log", text: "before")])

        let driverError = await session.evaluate(code: "await call('tab.missing');")
        #expect(driverError.error == "Error: no such tab")
    }

    @Test("An evaluation that never settles times out without wedging the session")
    func timeout() async {
        let driver = RecordingReplDriver()
        let session = makeSession(driver: driver)
        defer { session.close() }

        let hung = await session.evaluate(code: "await new Promise(() => {});", timeout: .milliseconds(50))
        #expect(hung.error?.contains("timed out") == true)

        let next = await session.evaluate(code: "console.log('alive');")
        #expect(next.lines == [BrowserReplOutputLine(level: "log", text: "alive")])
    }

    @Test("Driver events reach the runtime, and a finished download becomes readable")
    func downloadEventAllowsReading() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-session-\(UUID().uuidString)")
        let work = base.appendingPathComponent("work")
        let downloads = base.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = downloads.appendingPathComponent("report.csv")
        try Data("a,b".utf8).write(to: file)

        let driver = RecordingReplDriver()
        // The scratch tree lives in the real temporary directory; point the
        // session's temporary root elsewhere so the download starts unreadable.
        let session = makeSession(driver: driver, cwd: work.path, temporaryDirectory: base.appendingPathComponent("tmp").path)
        defer { session.close() }

        let before = await session.evaluate(code: "fs('readFile', { path: \(quoted(file.path)) });")
        #expect(before.error == "Error: EACCES")

        driver.emit("download.finished", #"{"targetId":"t1","downloadId":"d1","path":\#(quoted(file.path))}"#)
        let after = await session.evaluate(
            code: """
            console.log(lastEvent[0], fs('readFile', { path: \(quoted(file.path)) }));
            """
        )
        #expect(after.error == nil)
        #expect(after.lines == [BrowserReplOutputLine(level: "log", text: "download.finished YSxi")])
    }

    @Test(
        "A working directory that holds the user's files is refused as the fs root",
        arguments: [
            "/",
            NSHomeDirectory(),
            NSHomeDirectory() + "/",
            (NSHomeDirectory() as NSString).deletingLastPathComponent,
        ]
    )
    func broadWorkingDirectoryIsRefused(cwd: String) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let session = makeSession(driver: RecordingReplDriver(), cwd: work.path)
        defer { session.close() }

        let refused = await session.evaluate(code: "console.log('ran');", cwd: cwd)

        #expect(refused.lines.isEmpty)
        #expect(refused.error?.contains("refusing to use") == true)
        #expect(refused.error?.contains("cd to a project or scratch directory") == true)
        #expect(session.cwd == work.path)
        let next = await session.evaluate(code: "console.log('ran');")
        #expect(next.error == nil)
        #expect(next.lines == [BrowserReplOutputLine(level: "log", text: "ran")])
    }

    @Test("A session created with / as its working directory refuses to evaluate")
    func sessionCreatedAtFileSystemRootIsRefused() async {
        let session = makeSession(driver: RecordingReplDriver(), cwd: "/")
        defer { session.close() }

        let refused = await session.evaluate(code: "console.log(fs('exists', { path: '/etc/hosts' }));")

        #expect(refused.lines.isEmpty)
        #expect(refused.error?.contains("refusing to use '/'") == true)
    }

    @Test("A session without a cwd gets its own temporary directory, removed on close when empty")
    func sessionWithoutWorkingDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func make(_ id: String) -> BrowserReplSession {
            BrowserReplSession(
                id: id,
                cwd: nil,
                bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "stub.js", source: stubRuntime)], agentScripts: []),
                driver: RecordingReplDriver(),
                temporaryDirectory: base.path
            )
        }
        let writer = make("writer/../session")
        let idle = make("idle")
        let canonicalBase = BrowserReplFileSandbox.canonicalize(base.path)

        #expect(writer.cwd != idle.cwd)
        for session in [writer, idle] {
            #expect((session.cwd as NSString).deletingLastPathComponent == canonicalBase + "/cmux-browser-repl")
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        let wrote = await writer.evaluate(code: "fs('writeFile', { path: 'out.txt', base64: 'aGk=' }); console.log(native.cwd);")
        #expect(wrote.error == nil)
        #expect(wrote.lines == [BrowserReplOutputLine(level: "log", text: writer.cwd)])

        writer.close()
        idle.close()
        #expect(FileManager.default.contents(atPath: writer.cwd + "/out.txt") == Data("hi".utf8))
        #expect(!FileManager.default.fileExists(atPath: idle.cwd))
    }

    @Test("Each session's temporary directory is private to it and never reaches another session's files")
    func temporaryDirectoryIsPrivateToTheSession() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-session-\(UUID().uuidString)")
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = BrowserReplFileSandbox.canonicalize(base.path)
        try Data("x".utf8).write(to: base.appendingPathComponent("other-app-file.txt"))
        func make(_ id: String) -> BrowserReplSession {
            BrowserReplSession(
                id: id,
                cwd: base.appendingPathComponent(id).path,
                bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "stub.js", source: stubRuntime)], agentScripts: []),
                driver: RecordingReplDriver(),
                temporaryDirectory: base.path
            )
        }
        let first = make("a")
        let second = make("b")
        defer {
            first.close()
            second.close()
        }

        // A spill file in the first session's temporary directory, as the runtime writes one.
        let wrote = await first.evaluate(code: "fs('writeFile', { path: native.tmpdir + '/output-1.txt', base64: 'aGk=' }); console.log(native.tmpdir);")
        #expect(wrote.error == nil)
        let firstTemporary = try #require(wrote.lines.first?.text)
        let listed = await second.evaluate(code: "console.log(native.tmpdir);")
        let secondTemporary = try #require(listed.lines.first?.text)
        #expect(firstTemporary != shared && secondTemporary != shared && firstTemporary != secondTemporary)
        for path in [firstTemporary, secondTemporary] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700, "\(path)")
        }

        // The other session reaches neither that file, nor the shared directory, nor other files in it.
        for code in [
            "fs('readFile', { path: \(quoted(firstTemporary + "/output-1.txt")) });",
            "fs('writeFile', { path: \(quoted(firstTemporary + "/output-1.txt")), base64: '' });",
            "fs('readdir', { path: \(quoted(shared)) });",
            "fs('readFile', { path: \(quoted(shared + "/other-app-file.txt")) });",
        ] {
            let refused = await second.evaluate(code: code)
            #expect(refused.error == "Error: EACCES", "\(code)")
        }
        #expect(FileManager.default.contents(atPath: firstTemporary + "/output-1.txt") == Data("hi".utf8))

        // Closing removes an empty temporary directory; files the session wrote stay readable.
        first.close()
        second.close()
        #expect(!FileManager.default.fileExists(atPath: secondTemporary))
        #expect(FileManager.default.contents(atPath: firstTemporary + "/output-1.txt") == Data("hi".utf8))
    }

    @Test("A session without a cwd gets a working directory only its user can open, under a private parent")
    func sessionWithoutWorkingDirectoryIsPrivate() throws {
        let fileManager = FileManager.default
        for preexisting in [false, true] {
            let base = fileManager.temporaryDirectory.appendingPathComponent("cmux-repl-session-\(UUID().uuidString)")
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: base) }
            let parent = BrowserReplFileSandbox.canonicalize(base.path) + "/cmux-browser-repl"
            if preexisting {
                // A parent an earlier version created world-readable is narrowed.
                try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            }
            let session = BrowserReplSession(
                id: "private",
                cwd: nil,
                bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "stub.js", source: stubRuntime)], agentScripts: []),
                driver: RecordingReplDriver(),
                temporaryDirectory: base.path
            )
            defer { session.close() }

            for path in [session.cwd, parent] {
                let mode = try fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
                #expect(mode?.intValue == 0o700, "\(path), parent existed: \(preexisting)")
            }
        }
    }

    @Test("The injected home directory is the one refused")
    func injectedHomeDirectoryIsRefused() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = BrowserReplSession(
            id: "home",
            cwd: home.appendingPathComponent("project").path,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "stub.js", source: stubRuntime)], agentScripts: []),
            driver: RecordingReplDriver(),
            homeDirectory: home.path
        )
        defer { session.close() }

        let project = await session.evaluate(code: "console.log(native.homedir);")
        let refused = await session.evaluate(code: "console.log('ran');", cwd: home.path + "/project/..")

        #expect(project.lines == [BrowserReplOutputLine(level: "log", text: home.path)])
        #expect(refused.lines.isEmpty)
        #expect(refused.error?.contains("refusing to use the home directory") == true)
    }

    @Test("A closed session refuses evaluations")
    func closedSession() async {
        let session = makeSession(driver: RecordingReplDriver())
        session.close()
        let result = await session.evaluate(code: "1")
        #expect(result.error?.contains("closed") == true)
    }

    private func quoted(_ string: String) -> String {
        JSONSerialization.browserReplString(string) ?? "\"\""
    }
}
