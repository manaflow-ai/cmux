import CMUXMobileCore

struct SimulatorStreamSurfaceActions: Sendable {
    let pointer: @Sendable (MobileSimulatorPointerInput) async -> Void
    let text: @Sendable (MobileSimulatorTextInput) async -> Void
    let button: @Sendable (MobileSimulatorButtonInput) async -> Void
    let coordinate: @Sendable (String, Double, Double, DiagnosticSimulatorCoordinateState) async -> Void
    let frameDiagnostic: @Sendable (String, DiagnosticSimulatorFrameLifecycle, UInt64?, Int?) async -> Void
    let presentationStalled: @Sendable (String) async -> Void
    let presentationSucceeded: @Sendable (String) async -> Void
    let inputDiagnostic: @Sendable (String, DiagnosticSimulatorInputLifecycle, DiagnosticSimulatorInputKind, Int?) async -> Void

    init(
        pointer: @escaping @Sendable (MobileSimulatorPointerInput) async -> Void,
        text: @escaping @Sendable (MobileSimulatorTextInput) async -> Void,
        button: @escaping @Sendable (MobileSimulatorButtonInput) async -> Void,
        coordinate: @escaping @Sendable (
            String,
            Double,
            Double,
            DiagnosticSimulatorCoordinateState
        ) async -> Void,
        frameDiagnostic: @escaping @Sendable (
            String,
            DiagnosticSimulatorFrameLifecycle,
            UInt64?,
            Int?
        ) async -> Void,
        presentationStalled: @escaping @Sendable (String) async -> Void,
        presentationSucceeded: @escaping @Sendable (String) async -> Void,
        inputDiagnostic: @escaping @Sendable (
            String,
            DiagnosticSimulatorInputLifecycle,
            DiagnosticSimulatorInputKind,
            Int?
        ) async -> Void
    ) {
        self.pointer = pointer
        self.text = text
        self.button = button
        self.coordinate = coordinate
        self.frameDiagnostic = frameDiagnostic
        self.presentationStalled = presentationStalled
        self.presentationSucceeded = presentationSucceeded
        self.inputDiagnostic = inputDiagnostic
    }
}
