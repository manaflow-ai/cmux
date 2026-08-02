import CMUXMobileCore

struct SimulatorStreamSurfaceActions: Sendable {
    let pointer: @Sendable (MobileSimulatorPointerInput) async -> Void
    let text: @Sendable (MobileSimulatorTextInput) async -> Void
    let button: @Sendable (MobileSimulatorButtonInput) async -> Void

    init(
        pointer: @escaping @Sendable (MobileSimulatorPointerInput) async -> Void,
        text: @escaping @Sendable (MobileSimulatorTextInput) async -> Void,
        button: @escaping @Sendable (MobileSimulatorButtonInput) async -> Void
    ) {
        self.pointer = pointer
        self.text = text
        self.button = button
    }
}
