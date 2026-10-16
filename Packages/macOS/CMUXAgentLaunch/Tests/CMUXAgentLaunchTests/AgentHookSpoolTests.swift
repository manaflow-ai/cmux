import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("AgentHookSpool")
struct AgentHookSpoolTests {
    private func makeSpool() throws -> AgentHookSpoolDirectory {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-spool-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let spool = AgentHookSpoolDirectory(url: url)
        #expect(spool.createLockFiles())
        #expect(spool.publishEnvironmentKeys(["CMUX_SURFACE_ID", "CMUX_CLAUDE_PID", "PWD", "UNSET_KEY", "lower"]))
        return spool
    }

    /// Runs the generated hook command the way Claude Code does.
    private func runHook(
        _ spool: AgentHookSpoolDirectory,
        subcommand: String,
        payload: Data,
        fallback: String = "printf FALLBACK; /bin/cat"
    ) throws -> String {
        let command = AgentHookSpoolProducer(agent: "claude").command(subcommand: subcommand, fallback: fallback)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_CLAUDE_HOOK_SPOOL_DIR": spool.url.path,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func records(_ spool: AgentHookSpoolDirectory) -> [AgentHookSpoolRecord] {
        spool.publishedRecordNames().compactMap { spool.claim(name: $0) }
    }

    @Test("Records round-trip and reject malformed headers")
    func recordFormat() {
        let record = AgentHookSpoolRecord(
            agent: "claude", subcommand: "pre-tool-use",
            environment: ["A": "x=y\nz", "B": ""], payload: Data("{\"k\":\"日本語\"}\n\0tail".utf8)
        )
        #expect(AgentHookSpoolRecord(data: record.encoded()) == record)
        #expect(AgentHookSpoolRecord(data: Data("other-v1\nclaude\nstop\n\0{}".utf8)) == nil)
        #expect(AgentHookSpoolRecord(data: Data("cmux-agent-hook-v1\nclaude\n../x\n\0{}".utf8)) == nil)
        #expect(AgentHookSpoolRecord(data: Data("cmux-agent-hook-v1\nclaude\nstop\nNOEQUALS\0\0{}".utf8)) == nil)
        #expect(AgentHookSpoolRecord(data: Data("cmux-agent-hook-v1\nclaude\nstop\nA=1\0".utf8)) == nil)
    }

    @Test("A live forwarder receives the hook's exact payload and captured environment")
    func publishesWithLiveForwarder() throws {
        let spool = try makeSpool()
        defer { spool.removeAll() }
        let lifetime = try #require(spool.lock(AgentHookSpoolDirectory.forwarderLockName, blocking: false))
        let payload = Data("{\"tool_name\":\"Read\",\"x\":\"日本語 'quoted' $HOME\\n\"}".utf8)
        #expect(try runHook(spool, subcommand: "pre-tool-use", payload: payload) == "{}\n")
        let published = records(spool)
        withExtendedLifetime(lifetime) {}
        #expect(published.count == 1)
        let record = try #require(published.first)
        #expect(record.agent == "claude")
        #expect(record.subcommand == "pre-tool-use")
        #expect(record.payload == payload)
        #expect(record.environment["CMUX_SURFACE_ID"] == "22222222-2222-2222-2222-222222222222")
        // The hook shell's parent is the agent when the wrapper did not export a PID.
        #expect(Int(record.environment["CMUX_CLAUDE_PID"] ?? "").map { $0 > 1 } == true)
        #expect(record.environment["PWD"] != nil)
        #expect(record.environment["UNSET_KEY"] == nil)
        #expect(record.environment["lower"] == nil)
    }

    @Test("Without a forwarder the producer reclaims its record and falls back with the full payload")
    func fallsBackWithoutForwarder() throws {
        let spool = try makeSpool()
        defer { spool.removeAll() }
        let payload = Data("{\"session_id\":\"s\",\"n\":1}".utf8)
        let output = try runHook(spool, subcommand: "stop", payload: payload)
        #expect(output == "FALLBACK" + String(decoding: payload, as: UTF8.self))
        #expect(spool.publishedRecordNames().isEmpty)
    }

    @Test("A retired spool and an oversized payload both use the fallback")
    func fallsBackWhenSpoolUnavailable() throws {
        let spool = try makeSpool()
        let lifetime = try #require(spool.lock(AgentHookSpoolDirectory.forwarderLockName, blocking: false))
        let large = Data(repeating: UInt8(ascii: "a"), count: AgentHookSpoolProducer.maximumPayloadBytes + 10)
        #expect(try runHook(spool, subcommand: "pre-tool-use", payload: large, fallback: "/usr/bin/wc -c")
            .trimmingCharacters(in: .whitespacesAndNewlines) == String(large.count))
        let retired = try #require(spool.retire())
        defer { retired.removeAll() }
        #expect(try runHook(spool, subcommand: "stop", payload: Data("{}".utf8)) == "FALLBACK{}")
        #expect(retired.publishedRecordNames().isEmpty)
        withExtendedLifetime(lifetime) {}
    }

    @Test("Sequential hooks are claimed in publication order, each exactly once")
    func publicationOrder() throws {
        let spool = try makeSpool()
        defer { spool.removeAll() }
        let lifetime = try #require(spool.lock(AgentHookSpoolDirectory.forwarderLockName, blocking: false))
        for index in 0..<5 {
            _ = try runHook(spool, subcommand: "pre-tool-use", payload: Data("{\"n\":\(index)}".utf8))
        }
        let names = spool.publishedRecordNames()
        let payloads = names.compactMap { spool.claim(name: $0) }.map { String(decoding: $0.payload, as: UTF8.self) }
        #expect(payloads == (0..<5).map { "{\"n\":\($0)}" })
        #expect(names.compactMap { spool.claim(name: $0) }.isEmpty)
        withExtendedLifetime(lifetime) {}
    }

    @Test("Record names order numerically, not lexically")
    func recordNameOrder() throws {
        let early = try #require(AgentHookSpoolRecordName("1790000000.99000000-5.rec"))
        let late = try #require(AgentHookSpoolRecordName("1790000000.100000000-4.rec"))
        #expect(early < late)
        #expect(AgentHookSpoolRecordName("keys") == nil)
        #expect(AgentHookSpoolRecordName("1.2-3.tmp") == nil)
        #expect(AgentHookSpoolRecordName("1.2--3.rec") == nil)
    }

    @Test("Cleanup refuses a directory that is not private")
    func refusesSharedDirectory() throws {
        let spool = try makeSpool()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spool.url.path)
        spool.removeAll()
        #expect(FileManager.default.fileExists(atPath: spool.url.path))
        try FileManager.default.removeItem(at: spool.url)
    }
}
