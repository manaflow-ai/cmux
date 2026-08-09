import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct AppLogTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Poll the drain barrier until `expected` entries have been written.
    private func waitForProcessed(_ log: AppLog, _ expected: Int) async throws {
        for _ in 0..<300 {
            if await log.processedCount() >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await log.processedCount() >= expected)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func routesEventsByDomain() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let networkURL = dir.appendingPathComponent("network.log")
        let log = AppLog(appFileURL: appURL, networkFileURL: networkURL, buildStamp: "test")

        log.ingest(DiagnosticEvent(
            .simulatorStreamLifecycle,
            surface: 7,
            a: DiagnosticSimulatorStreamLifecycle.started.rawValue
        ))
        log.ingest(DiagnosticEvent(.transportDialStarted, a: 1, c: 42))
        log.ingest(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.background.rawValue
        ))
        try await waitForProcessed(log, 3)
        await log.flushForTesting()

        let app = try contents(of: appURL)
        let network = try contents(of: networkURL)
        #expect(app.contains("simulatorStreamLifecycle") || app.contains("Simulator"))
        #expect(!network.contains("Simulator"))
        #expect(network.contains("dial") || network.contains("Dial"))
        #expect(!app.contains("dial") && !app.contains("Dial"))
        // Cross-cutting context lands in both files.
        let appLifecycleInApp = app.contains("lifecycle") || app.contains("Lifecycle")
        let appLifecycleInNetwork = network.contains("lifecycle") || network.contains("Lifecycle")
        #expect(appLifecycleInApp && appLifecycleInNetwork)
    }

    @Test func mirroredStringLinesLandInAppFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let networkURL = dir.appendingPathComponent("network.log")
        let log = AppLog(appFileURL: appURL, networkFileURL: networkURL, buildStamp: "test")

        log.mirrorAppLine("sim.stream state=1 panel=7")
        try await waitForProcessed(log, 1)

        #expect(try contents(of: appURL).contains("sim.stream state=1 panel=7"))
        #expect(try !contents(of: networkURL).contains("sim.stream"))
    }

    /// A steady frame stream costs one line plus one summary, not a line per
    /// frame; the summary flushes when the run breaks.
    @Test func coalescesConsecutiveFrameEvents() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let log = AppLog(appFileURL: appURL, networkFileURL: nil, buildStamp: "test")

        for sequence in 1...24 {
            log.ingest(DiagnosticEvent(
                .simulatorFrameLifecycle,
                surface: 7,
                a: DiagnosticSimulatorFrameLifecycle.received.rawValue,
                b: sequence
            ))
        }
        log.ingest(DiagnosticEvent(
            .simulatorStreamLifecycle,
            surface: 7,
            a: DiagnosticSimulatorStreamLifecycle.stalled.rawValue
        ))
        try await waitForProcessed(log, 25)

        let lines = try contents(of: appURL).split(separator: "\n")
        let frameLines = lines.filter { $0.contains("frame pipeline") }
        // First occurrence + one coalesced summary, flushed by the stalled
        // event that broke the run.
        #expect(frameLines.count == 2)
        #expect(frameLines.last?.contains("×24") == true)
        #expect(lines.last?.contains("Stalled") == true)
    }

    /// Exceeding the byte budget rotates the current generation to `.1` and
    /// keeps writing to a fresh file.
    @Test func rotatesWhenExceedingMaxBytes() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let log = AppLog(
            appFileURL: appURL,
            networkFileURL: nil,
            maxFileBytes: 512,
            buildStamp: "test"
        )

        for index in 0..<40 {
            log.mirrorAppLine("filler line \(index) 0123456789 0123456789")
        }
        try await waitForProcessed(log, 40)

        let rotated = appURL.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let active = try contents(of: appURL)
        #expect(active.contains("cmux app log"))
        #expect(try contents(of: rotated).contains("filler line"))
    }

    /// A failed launch-time rotation (busy file, read-only directory) must
    /// append to the existing log instead of truncating away the diagnostics
    /// a user may be about to share.
    @Test func failedRotationAppendsInsteadOfTruncating() async throws {
        let dir = try makeTempDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        let appURL = dir.appendingPathComponent("app.log")
        try Data("previous-generation marker\n".utf8).write(to: appURL)
        // A read-only parent makes the `.1` move fail while the existing
        // file itself stays writable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dir.path
        )

        let log = AppLog(appFileURL: appURL, networkFileURL: nil, buildStamp: "test")
        log.mirrorAppLine("post-failure line 1")
        log.mirrorAppLine("post-failure line 2")
        log.mirrorAppLine("post-failure line 3")
        try await waitForProcessed(log, 3)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.path
        )
        let contents = try contents(of: appURL)
        #expect(contents.contains("previous-generation marker"))
        #expect(contents.contains("post-failure line 1"))
        #expect(contents.contains("post-failure line 3"))
        // The fallback appends no session header: a sustained rotate failure
        // must not grow the file by one header per retried line.
        #expect(!contents.contains("cmux app log"))
        #expect(!FileManager.default.fileExists(
            atPath: appURL.appendingPathExtension("1").path
        ))
    }

    @Test func classificationCoversNetworkPlane() {
        #expect(DiagnosticEventCode.transportDialFailed.appLogDomain == .network)
        #expect(DiagnosticEventCode.sessionClosed.appLogDomain == .network)
        #expect(DiagnosticEventCode.discoveryFailed.appLogDomain == .network)
        #expect(DiagnosticEventCode.relayPolicyRefreshFailed.appLogDomain == .network)
        #expect(DiagnosticEventCode.simulatorInputLifecycle.appLogDomain == .app)
        #expect(DiagnosticEventCode.browserStreamLifecycle.appLogDomain == .app)
        #expect(DiagnosticEventCode.composerViewAppear.appLogDomain == .app)
        #expect(DiagnosticEventCode.appLifecycleChanged.appLogDomain == .both)
        #expect(DiagnosticEventCode.reachabilityChanged.appLogDomain == .both)
    }
}
