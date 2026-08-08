/// A retained one-shot action published across the native-access atomic gate.
final class TerminalSurfaceRuntimeTeardownAction: Sendable {
    private let start: @Sendable () -> Void

    init(start: @escaping @Sendable () -> Void) {
        self.start = start
    }

    func run() {
        start()
    }
}
