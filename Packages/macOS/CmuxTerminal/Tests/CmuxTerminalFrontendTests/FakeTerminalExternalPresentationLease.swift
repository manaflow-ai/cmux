import CmuxTerminalFrontend

final class FakeTerminalExternalPresentationLease: TerminalExternalPresentationLease {
    nonisolated func detach() {}
}
