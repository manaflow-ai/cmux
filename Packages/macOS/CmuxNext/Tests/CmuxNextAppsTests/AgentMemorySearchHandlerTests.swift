import CmuxNextApps
import Foundation
import Testing

/// `memory.search` of the Agent Memory app (`first-party-apps/memory`) answered
/// from the agent memory index (`optchat-chief agent-memory search --json`).
@MainActor
struct AgentMemorySearchHandlerTests {
    @Test func enabledSearchMapsIndexHitsToTheAppsHitShape() async throws {
        let index = AgentMemoryTestIndex(hits: [
            .init(id: 7, kind: "memory", date: "2026-10-12", source: "claude:proj/memory/deploy.md",
                  snippet: "rotate the [deploy] [key] monthly", text: "Rotate the deploy key monthly."),
            .init(id: 9, kind: "note", date: "2026-10-14", source: "note", snippet: "", text: "Deploy from main only."),
        ])
        let handler = AgentMemorySearchHandler(enabled: { true }, index: index)
        let reply = try await handler.handle(request(["roots": ["root_home"], "query": "  deploy key ", "limit": 5]))
        #expect(await index.queries == [.init(query: "deploy key", limit: 5)])
        #expect(reply == ["hits": [
            ["root": "agent-memory", "path": "claude:proj/memory/deploy.md", "line": 0,
             "text": "rotate the [deploy] [key] monthly", "id": 7, "date": "2026-10-12"],
            ["root": "agent-memory", "path": "note", "line": 0, "text": "Deploy from main only.", "id": 9, "date": "2026-10-14"],
        ]])
    }

    @Test func turnedOffMemoryLeavesTheOpUnsupportedSoTheAppFallsBack() async {
        let index = AgentMemoryTestIndex(hits: [])
        let handler = AgentMemorySearchHandler(enabled: { false }, index: index)
        await refusal(handler, ["roots": [], "query": "deploy"], code: "operation.unsupported")
        #expect(await index.queries.isEmpty)
    }

    @Test func aBuildWithoutTheIndexToolLeavesTheOpUnsupported() async {
        let handler = AgentMemorySearchHandler(enabled: { true }, index: nil)
        await refusal(handler, ["roots": [], "query": "deploy"], code: "operation.unsupported")
    }

    @Test func otherMemoryOpsStayUnsupported() async {
        let index = AgentMemoryTestIndex(hits: [])
        let handler = AgentMemorySearchHandler(enabled: { true }, index: index)
        for op in ["memory.roots", "memory.list", "memory.watch"] {
            await refusal(handler, ["root": "root_home"], code: "operation.unsupported", op: op)
        }
        #expect(await index.queries.isEmpty)
    }

    @Test func malformedParamsAreRefusedBeforeTheIndexRuns() async {
        let index = AgentMemoryTestIndex(hits: [])
        let handler = AgentMemorySearchHandler(enabled: { true }, index: index)
        let bad: [AppJSON] = [
            .null,
            ["roots": []],
            ["roots": [], "query": "   "],
            ["roots": [], "query": 3],
            ["roots": "root_home", "query": "deploy"],
            ["roots": [1], "query": "deploy"],
            ["roots": [], "query": "deploy", "limit": 0],
            ["roots": [], "query": "deploy", "limit": 2.5],
            ["roots": [], "query": "deploy", "path": "/etc/passwd"],
            ["roots": [], "query": .string(String(repeating: "x", count: 1025))],
        ]
        for params in bad { await refusal(handler, params, code: "validation.invalid") }
        #expect(await index.queries.isEmpty)
    }

    @Test func onlyTheAgentMemoryAppReadsTheIndex() async {
        let index = AgentMemoryTestIndex(hits: [])
        let handler = AgentMemorySearchHandler(enabled: { true }, index: index)
        do throws(AppHostCapabilityError) {
            _ = try await handler.handle(.init(app: "acme/notes", op: "memory.search", params: ["roots": [], "query": "deploy"], origin: "script"))
            Issue.record("another app read the agent memory index")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
        #expect(await index.queries.isEmpty)
    }

    @Test func aCancelledSearchIsCancelledNotAnOutage() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = try script(in: dir, "exec sleep 30")
        let task = Task { () -> String? in
            do throws(AppHostCapabilityError) {
                _ = try await BundledAgentMemoryIndex(executable: slow).search(query: "deploy", limit: 5)
                return nil
            } catch {
                return error.code
            }
        }
        task.cancel()
        #expect(await task.value == "operation.cancelled")
    }

    @Test func theBundledIndexNeedsAnExecutableTool() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BundledAgentMemoryIndex.bundled(resources: dir) == nil)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        _ = try script(in: dir.appendingPathComponent("bin"), "exit 0")
        #expect(BundledAgentMemoryIndex.bundled(resources: dir) != nil)
    }

    @Test func theLimitDefaultsAndIsCapped() async throws {
        let index = AgentMemoryTestIndex(hits: [])
        let handler = AgentMemorySearchHandler(enabled: { true }, index: index)
        _ = try await handler.handle(request(["roots": [], "query": "deploy"]))
        _ = try await handler.handle(request(["roots": [], "query": "deploy", "limit": 5000]))
        #expect(await index.queries == [.init(query: "deploy", limit: 20), .init(query: "deploy", limit: 200)])
    }

    @Test func theBundledToolGetsTheQueryAfterTheOptionsAndItsHitsAreParsed() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let argv = dir.appendingPathComponent("argv")
        let tool = try script(in: dir, """
            printf '%s\\n' "$@" > '\(argv.path)'
            printf '%s' '[{"id":3,"kind":"memory","date":"2026-10-01","source":"codex:memories/a.md","snippet":"[deploy]","text":"deploy"}]'
            """)
        let hits = try await BundledAgentMemoryIndex(executable: tool).search(query: "--deploy key", limit: 5)
        #expect(hits == [.init(id: 3, kind: "memory", date: "2026-10-01", source: "codex:memories/a.md", snippet: "[deploy]", text: "deploy")])
        let recorded = try String(contentsOf: argv, encoding: .utf8)
        #expect(recorded == "agent-memory\nsearch\n--json\n--limit\n5\n--\n--deploy key\n")
    }

    @Test func aFailingToolIsAnUnavailableSearchAndAMissingToolIsUnsupported() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = try script(in: dir, "echo 'agent memory: owner unreachable' >&2; exit 1")
        await indexRefusal(BundledAgentMemoryIndex(executable: failing), code: "memory.unavailable")
        let garbage = try script(in: dir, "echo 'not json'", name: "garbage")
        await indexRefusal(BundledAgentMemoryIndex(executable: garbage), code: "memory.unavailable")
        await indexRefusal(BundledAgentMemoryIndex(executable: dir.appendingPathComponent("missing")), code: "operation.unsupported")
    }

    private func request(_ params: AppJSON, op: String = "memory.search") -> AppHostCapabilityRequest {
        .init(app: "cmux/memory", op: op, params: params, origin: "script")
    }

    private func refusal(_ handler: AgentMemorySearchHandler, _ params: AppJSON, code: String, op: String = "memory.search") async {
        do throws(AppHostCapabilityError) {
            _ = try await handler.handle(request(params, op: op))
            Issue.record("a refused memory request returned a result")
        } catch {
            #expect(error.code == code)
        }
    }

    private func indexRefusal(_ index: BundledAgentMemoryIndex, code: String) async {
        do throws(AppHostCapabilityError) {
            _ = try await index.search(query: "deploy", limit: 5)
            Issue.record("a failed index search returned hits")
        } catch {
            #expect(error.code == code)
        }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func script(in dir: URL, _ body: String, name: String = "optchat-chief") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Records the searches a handler sends and answers fixed hits.
actor AgentMemoryTestIndex: AgentMemoryIndex {
    struct Query: Equatable {
        var query: String
        var limit: Int
    }

    private let hits: [AgentMemoryHit]
    private(set) var queries: [Query] = []

    init(hits: [AgentMemoryHit]) {
        self.hits = hits
    }

    func search(query: String, limit: Int) async throws(AppHostCapabilityError) -> [AgentMemoryHit] {
        queries.append(.init(query: query, limit: limit))
        return hits
    }
}
