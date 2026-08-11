@testable import CmuxTerminal

final class FakeTerminalByteTeeLease: TerminalByteTeeLease {
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void = {}) {
        self.onRelease = onRelease
    }

    func release() {
        onRelease()
    }
}
