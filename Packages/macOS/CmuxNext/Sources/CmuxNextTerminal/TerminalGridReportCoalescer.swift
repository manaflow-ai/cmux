/// RED CONTROL shim (never merge): this product has no grid-report coalescer. The #36478 head's tests read only its
/// window length (Ghostty.app's `min_ms`, 25 ms); no product code uses this type.
enum TerminalGridReportCoalescer {
    nonisolated static let defaultInterval: Duration = .milliseconds(25)
}
