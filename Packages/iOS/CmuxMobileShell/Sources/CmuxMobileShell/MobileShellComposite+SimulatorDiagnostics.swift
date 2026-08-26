public import CMUXMobileCore
internal import CmuxMobileDiagnostics
import Foundation
internal import OSLog

private let mobileSimulatorDiagnosticsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "simulator"
)

@MainActor
extension MobileShellComposite {
    static func simulatorPanelHandle(_ panelID: String) -> UInt32 {
        diagnosticSurfaceHandle(panelID)
    }

    static func diagnosticPointerPhase(
        _ phase: MobileSimulatorPointerPhase
    ) -> DiagnosticSimulatorPointerPhase {
        switch phase {
        case .began:
            return .began
        case .moved:
            return .moved
        case .ended:
            return .ended
        case .tap:
            return .tap
        }
    }

    static func diagnosticButtonKind(
        _ button: MobileSimulatorHardwareButton
    ) -> DiagnosticSimulatorHardwareButtonKind {
        switch button {
        case .home:
            return .home
        case .swipeHome:
            return .swipeHome
        case .appSwitcher:
            return .appSwitcher
        case .lock:
            return .lock
        case .siri:
            return .siri
        case .sideButton:
            return .sideButton
        case .power:
            return .power
        case .volumeUp:
            return .volumeUp
        case .volumeDown:
            return .volumeDown
        case .action:
            return .action
        case .watchSideButton:
            return .watchSideButton
        }
    }

    static func normalizedCoordinateUnit(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let clamped = min(1.0, max(0.0, value))
        return Int((clamped * 10_000.0).rounded())
    }

    func currentSimulatorOwnership(panelID: String) -> DiagnosticSimulatorOwnershipState {
        guard let state = simulatorStreamStore?.state(for: panelID) else { return .unknown }
        return MobileSimulatorStreamStore.diagnosticOwnershipState(
            ownerConnectionID: state.ownerConnectionID,
            isOwnedByCurrentConnection: state.isOwnedByCurrentConnection
        )
    }

    func recordSimulatorStream(
        panelID: String,
        state: DiagnosticSimulatorStreamLifecycle,
        ownership: DiagnosticSimulatorOwnershipState = .unknown,
        activeSessions: Int? = nil
    ) {
        let handle = Self.simulatorPanelHandle(panelID)
        diagnosticLog?.record(DiagnosticEvent(
            .simulatorStreamLifecycle,
            surface: handle,
            a: state.rawValue,
            b: ownership.rawValue,
            c: activeSessions
        ))
        mobileSimulatorDiagnosticsLog.info(
            "sim.stream state=\(state.rawValue, privacy: .public) panel=\(handle, privacy: .public) owner=\(ownership.rawValue, privacy: .public) sessions=\(activeSessions ?? -1, privacy: .public)"
        )
        MobileDebugLog.anchormux(
            "sim.stream state=\(state.rawValue) panel=\(handle) owner=\(ownership.rawValue) sessions=\(activeSessions ?? -1)"
        )
    }

    func recordSimulatorFrame(
        panelID: String,
        state: DiagnosticSimulatorFrameLifecycle,
        sequence: UInt64? = nil,
        payloadBytes: Int? = nil
    ) {
        let handle = Self.simulatorPanelHandle(panelID)
        let boundedSequence = sequence.map { Int(clamping: $0) }
        diagnosticLog?.record(DiagnosticEvent(
            .simulatorFrameLifecycle,
            surface: handle,
            a: state.rawValue,
            b: boundedSequence,
            c: payloadBytes
        ))
        mobileSimulatorDiagnosticsLog.info(
            "sim.frame state=\(state.rawValue, privacy: .public) panel=\(handle, privacy: .public) seq=\(boundedSequence ?? -1, privacy: .public) bytes=\(payloadBytes ?? -1, privacy: .public)"
        )
        MobileDebugLog.anchormux(
            "sim.frame state=\(state.rawValue) panel=\(handle) seq=\(boundedSequence ?? -1) bytes=\(payloadBytes ?? -1)"
        )
    }

    public func recordMobileSimulatorFrameDiagnostic(
        panelID: String,
        state: DiagnosticSimulatorFrameLifecycle,
        sequence: UInt64? = nil,
        payloadBytes: Int? = nil
    ) {
        recordSimulatorFrame(
            panelID: panelID,
            state: state,
            sequence: sequence,
            payloadBytes: payloadBytes
        )
    }

    func recordSimulatorInput(
        panelID: String,
        state: DiagnosticSimulatorInputLifecycle,
        kind: DiagnosticSimulatorInputKind,
        detail: Int? = nil
    ) {
        let handle = Self.simulatorPanelHandle(panelID)
        diagnosticLog?.record(DiagnosticEvent(
            .simulatorInputLifecycle,
            surface: handle,
            a: state.rawValue,
            b: kind.rawValue,
            c: detail
        ))
        mobileSimulatorDiagnosticsLog.info(
            "sim.input state=\(state.rawValue, privacy: .public) panel=\(handle, privacy: .public) kind=\(kind.rawValue, privacy: .public) detail=\(detail ?? -1, privacy: .public)"
        )
        MobileDebugLog.anchormux(
            "sim.input state=\(state.rawValue) panel=\(handle) kind=\(kind.rawValue) detail=\(detail ?? -1)"
        )
    }

    public func recordMobileSimulatorInputDiagnostic(
        panelID: String,
        state: DiagnosticSimulatorInputLifecycle,
        kind: DiagnosticSimulatorInputKind,
        detail: Int? = nil
    ) {
        recordSimulatorInput(panelID: panelID, state: state, kind: kind, detail: detail)
    }

    func recordSimulatorCoordinate(
        panelID: String,
        x: Double,
        y: Double,
        mapping: DiagnosticSimulatorCoordinateState
    ) {
        let handle = Self.simulatorPanelHandle(panelID)
        let normalizedX = Self.normalizedCoordinateUnit(x)
        let normalizedY = Self.normalizedCoordinateUnit(y)
        diagnosticLog?.record(DiagnosticEvent(
            .simulatorCoordinateMapped,
            surface: handle,
            a: normalizedX,
            b: normalizedY,
            c: mapping.rawValue
        ))
        mobileSimulatorDiagnosticsLog.info(
            "sim.coord panel=\(handle, privacy: .public) x=\(normalizedX, privacy: .public) y=\(normalizedY, privacy: .public) mapping=\(mapping.rawValue, privacy: .public)"
        )
        MobileDebugLog.anchormux(
            "sim.coord panel=\(handle) x=\(normalizedX) y=\(normalizedY) mapping=\(mapping.rawValue)"
        )
    }

    public func recordMobileSimulatorCoordinate(
        panelID: String,
        x: Double,
        y: Double,
        mapping: DiagnosticSimulatorCoordinateState
    ) {
        recordSimulatorCoordinate(panelID: panelID, x: x, y: y, mapping: mapping)
    }

    func recordSimulatorOwnership(
        panelID: String,
        ownership: DiagnosticSimulatorOwnershipState,
        previousOwnership: DiagnosticSimulatorOwnershipState?
    ) {
        let handle = Self.simulatorPanelHandle(panelID)
        diagnosticLog?.record(DiagnosticEvent(
            .simulatorOwnershipChanged,
            surface: handle,
            a: ownership.rawValue,
            b: previousOwnership?.rawValue
        ))
        mobileSimulatorDiagnosticsLog.info(
            "sim.owner panel=\(handle, privacy: .public) owner=\(ownership.rawValue, privacy: .public) previous=\(previousOwnership?.rawValue ?? -1, privacy: .public)"
        )
        MobileDebugLog.anchormux(
            "sim.owner panel=\(handle) owner=\(ownership.rawValue) previous=\(previousOwnership?.rawValue ?? -1)"
        )
    }
}
