#if os(iOS)
struct TerminalLoadingDiagnosticsRow: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let tone: TerminalLoadingDiagnosticsTone
}
#endif
