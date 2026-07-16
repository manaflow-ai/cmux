import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator private privacy containment")
struct SimulatorPrivatePrivacyAdapterTests {
    @Test("Database identifiers accept only the fixed safe alphabet")
    func safeIdentifiers() {
        #expect(simulatorPrivacyIdentifierIsSafe("com.example.camera-app"))
        #expect(simulatorPrivacyIdentifierIsSafe("8A44A2EF-22B1"))
        #expect(!simulatorPrivacyIdentifierIsSafe("com.example'; DELETE"))
        #expect(!simulatorPrivacyIdentifierIsSafe(""))
        #expect(!simulatorPrivacyIdentifierIsSafe(".."))
        #expect(!simulatorPrivacyIdentifierIsSafe("com.example.アプリ"))
        #expect(!simulatorPrivacyIdentifierIsSafe(String(repeating: "a", count: 256)))
    }

    @Test("Camera TCC updates are atomic and reset omits reinsertion")
    func cameraTCCTransaction() throws {
        let adapter = SimulatorPrivatePrivacyAdapter()
        let grant = try #require(adapter.tccMutationSQL(
            service: .camera,
            action: .grant,
            bundleIdentifier: "com.example.camera"
        ))
        let reset = try #require(adapter.tccMutationSQL(
            service: .camera,
            action: .reset,
            bundleIdentifier: "com.example.camera"
        ))

        #expect(grant.hasPrefix("BEGIN IMMEDIATE;"))
        #expect(grant.contains("kTCCServiceCamera"))
        #expect(grant.contains("INSERT INTO access"))
        #expect(grant.hasSuffix("COMMIT;"))
        #expect(reset.hasPrefix("BEGIN IMMEDIATE;"))
        #expect(!reset.contains("INSERT INTO access"))
        #expect(reset.hasSuffix("COMMIT;"))
    }

    @Test("Missing runtime stores read back as unknown without crashing")
    func missingRuntimeReadback() async {
        let isolatedDevicesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-runtime-\(UUID().uuidString)")
        let adapter = SimulatorPrivatePrivacyAdapter(
            simulatorDevicesDirectory: isolatedDevicesDirectory
        )
        let snapshot = await adapter.snapshot(
            deviceIdentifier: "00000000-0000-0000-0000-000000000000",
            bundleIdentifier: "com.example.missing"
        )

        #expect(snapshot.authorizations[.speech] == .unknown)
        #expect(snapshot.authorizations[.notifications] == .notDetermined)
        #expect(snapshot.authorizations[.location] == .notDetermined)
    }

    @Test("Runtime-wide TCC readback groups applications and stays bounded")
    func runtimeWideTCCReadback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tcc-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("TCC.db")
        let runner = SimulatorSubprocessRunner()
        var statements = [
            "CREATE TABLE access " +
                "(client TEXT, service TEXT, auth_value INTEGER, client_type INTEGER);",
            "INSERT INTO access VALUES " +
                "('com.example.camera', 'kTCCServiceCamera', 2, 0);",
            "INSERT INTO access VALUES " +
                "('com.example.camera', 'kTCCServiceMicrophone', 0, 0);",
            "INSERT INTO access VALUES " +
                "('invalid client', 'kTCCServiceCamera', 2, 0);",
        ]
        for index in 0...SimulatorPrivatePrivacyAdapter.maximumUnfilteredApplications {
            statements.append(
                "INSERT INTO access VALUES " +
                    "('com.example.fixture\(index)', 'kTCCServiceCamera', 2, 0);"
            )
        }
        let setup = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [databaseURL.path, statements.joined()]
        )
        #expect(setup.status == 0)

        let readback = try await SimulatorPrivatePrivacyAdapter()
            .readTCCApplicationRows(databaseURL: databaseURL)
        #expect(readback.isTruncated)
        #expect(
            readback.applications.count
                == SimulatorPrivatePrivacyAdapter.maximumUnfilteredApplications + 1
        )
        let camera = try #require(readback.applications.first {
            $0.bundleIdentifier == "com.example.camera"
        })
        #expect(camera.services["kTCCServiceCamera"] == 2)
        #expect(camera.services["kTCCServiceMicrophone"] == 0)
        #expect(!readback.applications.contains { $0.bundleIdentifier == "invalid client" })
    }

    @Test("Version-skewed public permission input returns a typed worker error")
    func rejectsUnsupportedTCCService() async {
        await #expect(throws: SimulatorWorkerFailure.self) {
            try await SimulatorPrivatePrivacyAdapter().setTCC(
                deviceIdentifier: "DEVICE",
                bundleIdentifier: "com.example.app",
                action: .grant,
                service: .microphone
            )
        }
    }

    @Test("Failed notification replacement preserves the original BulletinBoard store")
    func failedNotificationReplacementPreservesStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bulletin-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent(
            "DEVICE/data/Library/BulletinBoard/VersionedSectionInfo.plist"
        )
        try FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = try PropertyListSerialization.data(
            fromPropertyList: [
                "sectionInfo": ["com.example.app": ["marker": "original"]],
            ],
            format: .binary,
            options: 0
        )
        try original.write(to: store)
        let missingBlob = root.appendingPathComponent("missing-section.plist")
        let adapter = SimulatorPrivatePrivacyAdapter(simulatorDevicesDirectory: root)

        await #expect(throws: SimulatorWorkerFailure.self) {
            try await adapter.mutateNotifications(
                deviceIdentifier: "DEVICE",
                bundleIdentifier: "com.example.app",
                action: .grant,
                critical: false,
                blob: missingBlob
            )
        }

        #expect(try Data(contentsOf: store) == original)
    }

    @Test("SQLite owns bounded busy handling without worker retry polling")
    func sqliteBusyTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tcc-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("TCC.db")
        let runner = SimulatorSubprocessRunner()
        let setup = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                databaseURL.path,
                "CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES (1);",
            ]
        )
        #expect(setup.status == 0)

        let holder = Process()
        let holderInput = Pipe()
        let holderOutput = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        holder.arguments = [databaseURL.path]
        holder.standardInput = holderInput
        holder.standardOutput = holderOutput
        holder.standardError = FileHandle.nullDevice
        for handle in [
            holderInput.fileHandleForReading,
            holderInput.fileHandleForWriting,
            holderOutput.fileHandleForReading,
            holderOutput.fileHandleForWriting,
        ] {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFD)
            #expect(flags >= 0)
            #expect(fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0)
        }
        try holder.run()
        defer {
            try? holderInput.fileHandleForWriting.close()
            if holder.isRunning { holder.terminate() }
        }
        try holderInput.fileHandleForWriting.write(contentsOf: Data(
            "BEGIN EXCLUSIVE;\n.print LOCKED\n".utf8
        ))
        let marker = try holderOutput.fileHandleForReading.read(upToCount: 7)
        #expect(String(decoding: marker ?? Data(), as: UTF8.self) == "LOCKED\n")

        let adapter = SimulatorPrivatePrivacyAdapter(
            sqliteBusyTimeoutMilliseconds: 10
        )
        await #expect(throws: SimulatorWorkerFailure.self) {
            try await adapter.runSQLite(
                databaseURL: databaseURL,
                sql: "UPDATE sample SET value=2;"
            )
        }

        try holderInput.fileHandleForWriting.close()
        holder.waitUntilExit()
        try await adapter.runSQLite(
            databaseURL: databaseURL,
            sql: "UPDATE sample SET value=2;"
        )
        let readback = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [databaseURL.path, "SELECT value FROM sample;"]
        )
        #expect(readback.status == 0)
        #expect(readback.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }
}
