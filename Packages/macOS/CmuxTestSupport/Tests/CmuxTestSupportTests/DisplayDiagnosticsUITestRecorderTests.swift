import Foundation
import Testing
@testable import CmuxTestSupport

@MainActor
@Suite("DisplayDiagnosticsUITestRecorder")
struct DisplayDiagnosticsUITestRecorderTests {
    private final class FakeProvider: UITestDiagnosticsProviding {
        var snapshot: UITestDiagnosticsSnapshot
        private(set) var callCount = 0
        init(_ snapshot: UITestDiagnosticsSnapshot) { self.snapshot = snapshot }
        func currentUITestDiagnosticsSnapshot(environment: [String: String]) -> UITestDiagnosticsSnapshot {
            callCount += 1
            return snapshot
        }
    }

    private func scratchPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.json")
    }

    private func baseSnapshot(
        windows: [UITestDiagnosticsSnapshot.Window] = [],
        targetDisplayID: String = "",
        presentDisplayIDs: Set<UInt32> = [],
        render: UITestDiagnosticsSnapshot.Render? = nil,
        socket: UITestDiagnosticsSnapshot.Socket? = nil,
        portal: [String: String]? = nil
    ) -> UITestDiagnosticsSnapshot {
        UITestDiagnosticsSnapshot(
            processIdentifier: 4242,
            bundleIdentifier: "com.cmux.test",
            isRunningUnderXCTest: true,
            windows: windows,
            targetDisplayID: targetDisplayID,
            presentDisplayIDs: presentDisplayIDs,
            render: render,
            socket: socket,
            portal: portal,
            systemUptime: 12.5
        )
    }

    private func loadJSON(_ url: URL) throws -> [String: String] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
    }

    @Test func unsetDiagnosticsPathIsANoOp() {
        let provider = FakeProvider(baseSnapshot())
        let recorder = DisplayDiagnosticsUITestRecorder(provider: provider, environment: [:])
        recorder.write(stage: "x")
        #expect(provider.callCount == 0)
    }

    @Test func installIfNeededDoesNothing() {
        let provider = FakeProvider(baseSnapshot())
        let recorder = DisplayDiagnosticsUITestRecorder(provider: provider, environment: [:])
        recorder.installIfNeeded()
        #expect(provider.callCount == 0)
    }

    @Test func writesCoreWindowKeys() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(
            windows: [
                .init(identifier: "cmux.main", isVisible: true, screenDisplayID: 7),
                .init(identifier: "", isVisible: false, screenDisplayID: nil),
            ],
            targetDisplayID: "7",
            presentDisplayIDs: [7]
        ))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "didFinishLaunching")

        let payload = try loadJSON(url)
        #expect(payload["stage"] == "didFinishLaunching")
        #expect(payload["pid"] == "4242")
        #expect(payload["bundleId"] == "com.cmux.test")
        #expect(payload["isRunningUnderXCTest"] == "1")
        #expect(payload["windowsCount"] == "2")
        #expect(payload["windowIdentifiers"] == "cmux.main,")
        #expect(payload["windowVisibleFlags"] == "1,0")
        #expect(payload["windowScreenDisplayIDs"] == "7,")
        #expect(payload["uiTestTargetDisplayID"] == "7")
        #expect(payload["targetDisplayPresent"] == "1")
        #expect(payload["targetDisplayMoveSucceeded"] == "1")
    }

    @Test func targetDisplayAbsentEmitsZeroFlags() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(
            windows: [.init(identifier: "cmux.main", isVisible: true, screenDisplayID: 1)],
            targetDisplayID: "9",
            presentDisplayIDs: [1]
        ))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["targetDisplayPresent"] == "0")
        #expect(payload["targetDisplayMoveSucceeded"] == "0")
    }

    @Test func nonNumericTargetDisplayOmitsPresenceKeys() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(targetDisplayID: ""))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["targetDisplayPresent"] == nil)
        #expect(payload["targetDisplayMoveSucceeded"] == nil)
    }

    @Test func renderUnavailableEmitsEmptyValues() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(render: .unavailable))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["renderStatsAvailable"] == "0")
        #expect(payload["renderPanelId"] == "")
        #expect(payload["renderDrawCount"] == "")
        #expect(payload["renderDiagnosticsUpdatedAt"] == "12.500000")
    }

    @Test func renderAvailableEmitsStats() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let panelID = UUID()
        let provider = FakeProvider(baseSnapshot(render: .available(
            .init(
                panelID: panelID,
                drawCount: 3,
                presentCount: 4,
                lastPresentTime: 1.25,
                windowVisible: true,
                appIsActive: false,
                desiredFocus: true,
                isFirstResponder: false
            )
        )))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["renderStatsAvailable"] == "1")
        #expect(payload["renderPanelId"] == panelID.uuidString)
        #expect(payload["renderDrawCount"] == "3")
        #expect(payload["renderPresentCount"] == "4")
        #expect(payload["renderLastPresentTime"] == "1.250000")
        #expect(payload["renderWindowVisible"] == "1")
        #expect(payload["renderAppIsActive"] == "0")
        #expect(payload["renderDesiredFocus"] == "1")
        #expect(payload["renderIsFirstResponder"] == "0")
    }

    @Test func socketDisabledEmitsDisabledShape() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(socket: .disabled(expectedPath: "/tmp/x.sock")))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["socketExpectedPath"] == "/tmp/x.sock")
        #expect(payload["socketMode"] == "off")
        #expect(payload["socketReady"] == "0")
        #expect(payload["socketFailureSignals"] == "socket_disabled")
        #expect(payload["socketPathOwnedByListener"] == "0")
    }

    @Test func socketEnabledEmitsHealth() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(socket: .init(
            isEnabled: true,
            expectedPath: "/tmp/y.sock",
            mode: "stable",
            isReady: true,
            pingResponse: "PONG",
            isRunning: true,
            acceptLoopAlive: true,
            socketPathMatches: true,
            socketPathExists: true,
            socketPathOwnedByListener: false,
            failureSignals: ""
        )))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["socketExpectedPath"] == "/tmp/y.sock")
        #expect(payload["socketMode"] == "stable")
        #expect(payload["socketReady"] == "1")
        #expect(payload["socketPingResponse"] == "PONG")
        #expect(payload["socketPathOwnedByListener"] == "0")
        #expect(payload["socketFailureSignals"] == "")
    }

    @Test func portalKeysAreMerged() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(portal: [
            "portal_count": "2",
            "portal_hosted_mapping_count": "1",
        ]))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "s")

        let payload = try loadJSON(url)
        #expect(payload["portal_count"] == "2")
        #expect(payload["portal_hosted_mapping_count"] == "1")
    }

    @Test func successiveWritesMergeAndOverwriteStage() throws {
        let url = scratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(baseSnapshot(portal: ["portal_count": "1"]))
        let recorder = DisplayDiagnosticsUITestRecorder(
            provider: provider,
            environment: ["CMUX_UI_TEST_DIAGNOSTICS_PATH": url.path]
        )

        recorder.write(stage: "first")
        // A new snapshot with no portal section must not erase the prior
        // portal keys — they persist via the load-merge, exactly like the
        // legacy in-place writer.
        provider.snapshot = baseSnapshot()
        recorder.write(stage: "second")

        let payload = try loadJSON(url)
        #expect(payload["stage"] == "second")
        #expect(payload["portal_count"] == "1")
    }
}
