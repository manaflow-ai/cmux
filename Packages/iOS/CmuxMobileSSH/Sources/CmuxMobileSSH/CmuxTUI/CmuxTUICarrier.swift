public import Foundation

/// A full-duplex byte stream carrying cmux-tui protocol-12 JSON lines.
/// `CmuxTUIControl` frames lines itself and multiplexes attach, subscribe
/// and browser streams over the one carrier, so a carrier never opens more
/// streams. Output arrives as `.stdout`; `.closed` ends the stream.
/// `.stderr` and exit events are optional startup diagnostics.
public protocol CmuxTUICarrier: Sendable {
    var events: AsyncStream<SSHSessionEvent> { get }
    func write(_ data: Data) async throws
    func close() async
}

extension SSHSessionChannel: CmuxTUICarrier {}
