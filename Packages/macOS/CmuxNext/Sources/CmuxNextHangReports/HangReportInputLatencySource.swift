public import CmuxNextInputCore

/// Where a report's input latency comes from: the app passes an adapter over the
/// input latency reporter's field report (`InputLatencyReporter` in CmuxNextControl; the wiring is
/// p04-input-104). ``HangReportService`` turns recording on only while reports are on and its wire
/// schema carries input latency, previews without taking, takes for a report it builds, and
/// commits only once that report is queued.
///
/// ```swift
/// await source.setRecording(true)
/// let counts = await source.take()   // build, check, enqueue ...
/// await source.commit()
/// ```
public protocol HangReportInputLatencySource: Sendable {
    /// Starts (true) or stops (false) the field ledger. Off drops every count not committed, so
    /// nothing recorded while reports were off goes out later.
    func setRecording(_ on: Bool) async
    /// What the next report would carry, without taking it (View Hang Report's preview); nil
    /// while recording is off.
    func preview() async -> InputLatencySnapshot?
    /// The counts not yet in a queued report, held until ``commit()``: a report dropped before it
    /// was queued loses nothing, as the next take returns them again. Nil while recording is off.
    func take() async -> InputLatencySnapshot?
    /// The report holding the taken counts was queued: they are gone from the source.
    func commit() async
}
