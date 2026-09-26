@testable import CmuxTerminal

final class FakeTerminalByteTeeLease: TerminalByteTeeLease {
    @MainActor
    func release() {}
}
