public import Foundation

/// Where report bodies go. ``URLSessionHangReportTransport`` posts them to cmux.com; tests record them.
public protocol HangReportTransport: Sendable {
    /// Sends one report body.
    func send(_ body: Data) async -> HangReportTransportResult
}
