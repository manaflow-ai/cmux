import CMUXMobileCore
import Foundation
import OSLog

private let mobileSimulatorHostDiagnosticsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux",
    category: "mobile-simulator"
)

enum MobileSimulatorDiagnostics {
    static func panelHandle(_ panelID: UUID) -> UInt32 {
        var hasher = Hasher()
        hasher.combine(panelID.uuidString)
        return UInt32(truncatingIfNeeded: hasher.finalize())
    }

    static func recordStream(
        panelID: UUID?,
        state: DiagnosticSimulatorStreamLifecycle,
        ownership: DiagnosticSimulatorOwnershipState = .unknown,
        activeSessions: Int? = nil
    ) {
        let handle = panelID.map(panelHandle)
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .simulatorStreamLifecycle,
            surface: handle,
            a: state.rawValue,
            b: ownership.rawValue,
            c: activeSessions
        ))
        mobileSimulatorHostDiagnosticsLog.info(
            "sim.stream state=\(state.rawValue, privacy: .public) panel=\(handle.map { Int($0) } ?? -1, privacy: .public) owner=\(ownership.rawValue, privacy: .public) sessions=\(activeSessions ?? -1, privacy: .public)"
        )
    }

    static func recordFrame(
        panelID: UUID?,
        state: DiagnosticSimulatorFrameLifecycle,
        sequence: UInt64? = nil,
        payloadBytes: Int? = nil
    ) {
        let handle = panelID.map(panelHandle)
        let boundedSequence = sequence.map { Int(clamping: $0) }
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .simulatorFrameLifecycle,
            surface: handle,
            a: state.rawValue,
            b: boundedSequence,
            c: payloadBytes
        ))
        mobileSimulatorHostDiagnosticsLog.info(
            "sim.frame state=\(state.rawValue, privacy: .public) panel=\(handle.map { Int($0) } ?? -1, privacy: .public) seq=\(boundedSequence ?? -1, privacy: .public) bytes=\(payloadBytes ?? -1, privacy: .public)"
        )
    }

    static func recordFrameQueueShed(
        panelIDStrings: Set<String>,
        shedByteCount: Int
    ) {
        for panelIDString in panelIDStrings {
            recordFrame(
                panelID: UUID(uuidString: panelIDString),
                state: .staleIgnored,
                payloadBytes: shedByteCount
            )
        }
    }

    static func recordInput(
        panelID: UUID?,
        state: DiagnosticSimulatorInputLifecycle,
        kind: DiagnosticSimulatorInputKind,
        detail: Int? = nil
    ) {
        let handle = panelID.map(panelHandle)
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .simulatorInputLifecycle,
            surface: handle,
            a: state.rawValue,
            b: kind.rawValue,
            c: detail
        ))
        mobileSimulatorHostDiagnosticsLog.info(
            "sim.input state=\(state.rawValue, privacy: .public) panel=\(handle.map { Int($0) } ?? -1, privacy: .public) kind=\(kind.rawValue, privacy: .public) detail=\(detail ?? -1, privacy: .public)"
        )
    }

    static func recordCoordinate(
        panelID: UUID?,
        x: Double,
        y: Double,
        mapping: DiagnosticSimulatorCoordinateState
    ) {
        let handle = panelID.map(panelHandle)
        let normalizedX = normalizedCoordinateUnit(x)
        let normalizedY = normalizedCoordinateUnit(y)
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .simulatorCoordinateMapped,
            surface: handle,
            a: normalizedX,
            b: normalizedY,
            c: mapping.rawValue
        ))
        mobileSimulatorHostDiagnosticsLog.info(
            "sim.coord panel=\(handle.map { Int($0) } ?? -1, privacy: .public) x=\(normalizedX, privacy: .public) y=\(normalizedY, privacy: .public) mapping=\(mapping.rawValue, privacy: .public)"
        )
    }

    static func recordOwnership(
        panelID: UUID?,
        ownership: DiagnosticSimulatorOwnershipState,
        previousOwnership: DiagnosticSimulatorOwnershipState?
    ) {
        let handle = panelID.map(panelHandle)
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .simulatorOwnershipChanged,
            surface: handle,
            a: ownership.rawValue,
            b: previousOwnership?.rawValue
        ))
        mobileSimulatorHostDiagnosticsLog.info(
            "sim.owner panel=\(handle.map { Int($0) } ?? -1, privacy: .public) owner=\(ownership.rawValue, privacy: .public) previous=\(previousOwnership?.rawValue ?? -1, privacy: .public)"
        )
    }

    static func ownershipState(
        ownerConnectionID: UUID?,
        currentConnectionID: UUID?
    ) -> DiagnosticSimulatorOwnershipState {
        guard let ownerConnectionID else {
            return currentConnectionID == nil ? .unowned : .pendingHandshake
        }
        guard let currentConnectionID else { return .unknown }
        return ownerConnectionID == currentConnectionID ? .currentConnection : .otherConnection
    }

    static func pointerPhase(_ phase: MobileSimulatorPointerPhase) -> DiagnosticSimulatorPointerPhase {
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

    static func buttonKind(_ button: MobileSimulatorHardwareButton) -> DiagnosticSimulatorHardwareButtonKind {
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
}
