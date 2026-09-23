import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Codex writer recovery safety")
struct CodexWriterSafetyTests {
    @Test("recognizes the actual watcher launch arguments including global options")
    func watcherGlobalArguments() {
        for prefix in [["--socket", "/tmp/cmux.sock"], ["--socket", "/tmp/cmux.sock", "--password", "a b"]] {
            let arguments = ["/opt/bin/cmux"] + prefix + ["__codex-teams-watch", "--workspace-id", "workspace", "--app-server-url", "ws://127.0.0.1:59152"]
            let watcher = CodexWriterProcessEvidence(
                pid: 12345, parentPID: 1, command: arguments.joined(separator: " "),
                executablePath: "/opt/bin/cmux", arguments: arguments
            )
            #expect(watcher.watcherAppServerPort == 59152)
        }
    }

    @Test("libproc descriptor failure is not an empty successful snapshot")
    func descriptorFailure() {
        #expect(CodexWriterSystemProcesses(temporaryDirectory: FileManager.default.temporaryDirectory).fileDescriptors(Int32.max) == nil)
    }

    @Test("parses only explicit recovery arguments")
    func recoveryArguments() {
        let identifier = UUID().uuidString
        #expect(CodexWriterRecoveryRequest(arguments: ["recover", identifier, "--yes"])?.confirmsTermination == true)
        #expect(CodexWriterRecoveryRequest(arguments: ["recover", identifier, "--codex-home", "/tmp/a b"])?.codexHome == "/tmp/a b")
        for arguments in [
            ["recover", "--yes", identifier], ["recover", identifier, "--yes", "--typo"],
            ["recover", identifier, "--codex-home", "--yes"], ["recover", identifier, "--", "--yes"],
            ["recover", identifier, "--yes", "--yes"], ["recover", identifier, "--codex-home"]
        ] {
            #expect(CodexWriterRecoveryRequest(arguments: arguments) == nil)
        }
    }

    @Test("kernel argv decoding preserves spaces and Japanese, excluding the environment")
    func argumentDecoding() {
        let argv = ["/tmp/日本語 tools/codex", "app-server", "--listen", "ws://127.0.0.1:59152"]
        var count = Int32(argv.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/tmp/日本語 tools/codex".utf8) + [0, 0, 0]
        for value in argv { bytes += Array(value.utf8) + [0] }
        bytes += Array("SECRET=not-an-argument".utf8) + [0]
        #expect(CodexWriterProcessArguments().decode(bytes) == argv)
        #expect(CodexWriterProcessArguments().decode([0, 0, 0, 0]) == nil)
        #expect(CodexWriterProcessArguments().decode(Array(bytes.prefix(12))) == nil)
    }

    @Test("a 200-thread batch shares one snapshot and deduplicates thread IDs")
    func batchSnapshot() throws {
        let fixture = try LockFixture(count: 200)
        defer { fixture.close() }
        let system = ProcessFixture()
        let reports = CodexWriterRecovery(processes: system).inspect(
            sessionIDs: fixture.identifiers + fixture.identifiers, codexHome: fixture.home.path
        )
        #expect(reports.count == 200)
        #expect(reports.values.allSatisfy { $0.lock.state == .active })
        #expect(system.calls == 1)
        #expect(system.targetCount == 200)
    }

    @Test("fresh ownership or process-generation changes prevent signalling", arguments: ["generation", "watcher", "incomplete", "holder", "clear"])
    func changedOwnershipRefusesTermination(change: String) throws {
        let fixture = try LockFixture(count: 1)
        defer { fixture.close() }
        let system = ProcessFixture(change: change)
        let recovery = CodexWriterRecovery(processes: system)
        #expect(!recovery.terminateOrphanedHolder(sessionID: fixture.identifiers[0], codexHome: fixture.home.path, pid: 12345))
        #expect(system.signals == 0)
    }

    @Test("unchanged proven ownership signals once using captured identity")
    func provenOwnership() throws {
        let fixture = try LockFixture(count: 1)
        defer { fixture.close() }
        let system = ProcessFixture()
        #expect(CodexWriterRecovery(processes: system).terminateOrphanedHolder(
            sessionID: fixture.identifiers[0], codexHome: fixture.home.path, pid: 12345
        ))
        #expect(system.signals == 1)
        #expect(system.calls == 2)
    }

    /// Synchronous fixture methods serialize their counters; assertions run after each call.
    private final class ProcessFixture: CodexWriterProcessInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var signals = 0
        private(set) var targetCount = 0
        let change: String?

        init(change: String? = nil) { self.change = change }

        func snapshot(locks: [CodexWriterLockInspection]) -> CodexWriterProcessSnapshot {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            targetCount = locks.count
            let changing = calls == 2
            let holder = CodexWriterProcessEvidence(
                pid: 12345, parentPID: 1, command: "codex app-server --listen ws://127.0.0.1:59152",
                startTime: "123:456", executablePath: "/opt/bin/codex",
                pidVersion: changing && change == "generation" ? 2 : 1,
                isPrivateCmuxServer: true,
                hasConnectedClients: false,
                hasControllingTerminal: false
            )
            var snapshot = CodexWriterProcessSnapshot()
            for target in locks.compactMap(CodexWriterFileIdentity.init) {
                snapshot.holders[target] = changing && change == "clear" ? [] : [holder]
                if changing && change == "holder" { snapshot.holders[target]?.append(holder) }
            }
            snapshot.isComplete = !(changing && change == "incomplete")
            if changing && change == "watcher" { snapshot.watchedPorts.insert(59152) }
            return snapshot
        }

        func terminate(_ holder: CodexWriterProcessEvidence) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            signals += 1
            return holder.pidVersion == 1
        }
    }

    private struct LockFixture {
        let home: URL
        let identifiers: [String]
        let descriptors: [Int32]

        init(count: Int) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let directory = home.appendingPathComponent("thread-writer-locks")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            identifiers = (0..<count).map { _ in UUID().uuidString.lowercased() }
            descriptors = identifiers.map {
                let descriptor = Darwin.open(directory.appendingPathComponent($0 + ".lock").path, O_CREAT | O_RDWR, 0o600)
                #expect(descriptor >= 0)
                #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
                return descriptor
            }
        }

        func close() {
            for descriptor in descriptors { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: home)
        }
    }
}
