public import Foundation

/// Assembles and writes the display / render / socket / portal diagnostics
/// payload for the `CMUX_UI_TEST_DIAGNOSTICS_PATH` XCUITest scenario.
///
/// This recorder owns the byte-identical `[String: String]` JSON payload the
/// legacy `AppDelegate.writeUITestDiagnosticsIfNeeded(stage:)` produced and
/// writes it to the path in `CMUX_UI_TEST_DIAGNOSTICS_PATH`. It reads no live
/// app state directly; the app target's ``UITestDiagnosticsProviding`` conformer
/// gathers that on the main actor and hands it over as a `Sendable`
/// ``UITestDiagnosticsSnapshot``.
///
/// Unlike the line/JSON appenders in ``UITestCaptureSink``, the diagnostics
/// file is read back as `[String: String]`, merged, and re-serialized with
/// **unsorted** keys (`JSONSerialization.data(withJSONObject:)` with no
/// options) to match the legacy writer byte-for-byte; the sorted-keys mutate
/// in ``UITestCaptureSink`` would change the on-disk key order, so this
/// recorder owns its own merge-and-write.
///
/// The app calls ``write(stage:)`` for every legacy
/// `writeUITestDiagnosticsIfNeeded(stage:)` call site. The
/// notification-observer wiring that re-writes the file on window/portal
/// changes stays in the app target: it binds to AppKit `NSWindow`
/// notification names and app-internal notification names, so it is an
/// irreducible AppKit/app seam, not package logic. ``installIfNeeded()`` is
/// therefore a no-op; the recorder is purely the payload writer.
@MainActor
public final class DisplayDiagnosticsUITestRecorder: UITestRecording {
    private let provider: any UITestDiagnosticsProviding
    private let environment: [String: String]

    /// Creates a diagnostics recorder.
    ///
    /// - Parameters:
    ///   - provider: The app-target seam supplying live diagnostics state.
    ///   - environment: The process environment; tests pass a fixture.
    public init(
        provider: any UITestDiagnosticsProviding,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.provider = provider
        self.environment = environment
    }

    public func installIfNeeded() {}

    /// Writes the diagnostics payload for `stage`, or does nothing when
    /// `CMUX_UI_TEST_DIAGNOSTICS_PATH` is unset.
    public func write(stage: String) {
        guard let path = environment["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = Self.load(at: path)
        let snapshot = provider.currentUITestDiagnosticsSnapshot(environment: environment)
        Self.merge(snapshot, stage: stage, into: &payload)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Payload assembly (byte-faithful with the legacy writer)

    private static func load(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private static func merge(
        _ snapshot: UITestDiagnosticsSnapshot,
        stage: String,
        into payload: inout [String: String]
    ) {
        let ids = snapshot.windows.map(\.identifier).joined(separator: ",")
        let vis = snapshot.windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        let screenIDs = snapshot.windows
            .map { $0.screenDisplayID.map(String.init) ?? "" }
            .joined(separator: ",")

        payload["stage"] = stage
        payload["pid"] = String(snapshot.processIdentifier)
        payload["bundleId"] = snapshot.bundleIdentifier
        payload["isRunningUnderXCTest"] = snapshot.isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(snapshot.windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis
        payload["windowScreenDisplayIDs"] = screenIDs
        payload["uiTestTargetDisplayID"] = snapshot.targetDisplayID
        if let rawDisplayID = UInt32(snapshot.targetDisplayID) {
            let screenPresent = snapshot.presentDisplayIDs.contains(rawDisplayID)
            let movedWindow = snapshot.windows.contains { $0.screenDisplayID == rawDisplayID }
            payload["targetDisplayPresent"] = screenPresent ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = movedWindow ? "1" : "0"
        }

        mergeRender(snapshot, into: &payload)
        mergeSocket(snapshot, into: &payload)
        mergePortal(snapshot, into: &payload)
    }

    private static func mergeRender(
        _ snapshot: UITestDiagnosticsSnapshot,
        into payload: inout [String: String]
    ) {
        guard let render = snapshot.render else { return }
        switch render {
        case .unavailable:
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", snapshot.systemUptime)
        case .available(let stats):
            payload["renderStatsAvailable"] = "1"
            payload["renderPanelId"] = stats.panelID.uuidString
            payload["renderDrawCount"] = String(stats.drawCount)
            payload["renderPresentCount"] = String(stats.presentCount)
            payload["renderLastPresentTime"] = String(format: "%.6f", stats.lastPresentTime)
            payload["renderWindowVisible"] = stats.windowVisible ? "1" : "0"
            payload["renderAppIsActive"] = stats.appIsActive ? "1" : "0"
            payload["renderDesiredFocus"] = stats.desiredFocus ? "1" : "0"
            payload["renderIsFirstResponder"] = stats.isFirstResponder ? "1" : "0"
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", snapshot.systemUptime)
        }
    }

    private static func mergeSocket(
        _ snapshot: UITestDiagnosticsSnapshot,
        into payload: inout [String: String]
    ) {
        guard let socket = snapshot.socket else { return }
        payload["socketExpectedPath"] = socket.expectedPath
        payload["socketMode"] = socket.mode
        payload["socketReady"] = socket.isReady ? "1" : "0"
        payload["socketPingResponse"] = socket.pingResponse
        payload["socketIsRunning"] = socket.isRunning ? "1" : "0"
        payload["socketAcceptLoopAlive"] = socket.acceptLoopAlive ? "1" : "0"
        payload["socketPathMatches"] = socket.socketPathMatches ? "1" : "0"
        payload["socketPathExists"] = socket.socketPathExists ? "1" : "0"
        payload["socketPathOwnedByListener"] = socket.socketPathOwnedByListener ? "1" : "0"
        payload["socketFailureSignals"] = socket.failureSignals
    }

    private static func mergePortal(
        _ snapshot: UITestDiagnosticsSnapshot,
        into payload: inout [String: String]
    ) {
        guard let portal = snapshot.portal else { return }
        for (key, value) in portal {
            payload[key] = value
        }
    }
}
