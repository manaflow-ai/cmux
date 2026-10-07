public import CmuxTerminalStream
public import Foundation

/// The seam between a carrier and the Ghostty renderer. Every way bytes
/// reach a terminal on the phone implements it: the cmux session host over
/// `CmuxLink` (lane C1, `.host`), an SSH channel (lane C9, `.local`) and the
/// fixture replay of the benchmark screen (`.local`). The renderer never
/// imports a transport.
///
/// Contract:
/// - `open` starts one connection and returns its events in channel order.
///   Calling `open` again replaces the connection; viewer state from the old
///   one is void. The stream finishes when the source closes.
/// - `send` delivers encoded input (keys, committed text, pastes already
///   bracketed by Ghostty, and for `.local` the terminal's query replies) in
///   call order, attributed to this viewer. Nothing queues while offline:
///   it throws instead.
/// - `viewportChanged` reports presence at once (`visible: false` when the
///   view leaves the screen or the app goes to the background) and the
///   viewport at the end of a rotation, split change or pinch, never during
///   it and never for the software keyboard.
/// - `requestSnapshot` (`.host` only) sends `snapshot_request`; the answer is
///   a `snapshot_ready` frame or `snapshotThrottled`. `.local` sources ignore it.
/// - Callbacks never block on the renderer; the renderer never blocks on them.
public protocol TerminalByteSource: AnyObject, Sendable {
    var authority: TerminalAuthority { get }
    /// The id carried in `snapshot_request.terminal` (`term_…` for the cmux host).
    var terminalID: String { get }
    func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent>
    func send(_ input: Data) async throws
    func viewportChanged(_ viewport: TerminalViewport) async
    func requestSnapshot(_ request: SnapshotRequest) async throws
    func close() async
}
