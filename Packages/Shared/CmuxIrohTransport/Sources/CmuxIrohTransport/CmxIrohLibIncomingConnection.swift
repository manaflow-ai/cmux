import Foundation
import IrohLib

/// One un-handshaken incoming iroh connection attempt.
///
/// ``establish()`` performs the server-side handshake (`Incoming.accept`,
/// ALPN validation, handshake completion) that used to run inline in the
/// endpoint's accept path. The underlying driver bounds a peer that stops
/// making progress with its own handshake/idle timeout, and dropping the
/// consumed attempt aborts it, so a stalled attempt can only ever cost its
/// own admission slot.
struct CmxIrohLibIncomingConnection: CmxIrohIncomingConnection {
    let incoming: Incoming
    let alpns: Set<Data>

    func establish() async throws -> any CmxIrohConnection {
        let accepting = try await incoming.accept()
        guard alpns.contains(try await accepting.alpn()) else {
            throw CmxIrohLibError.unexpectedALPN
        }
        return try CmxIrohLibConnection(driver: await accepting.connect())
    }

    func abandon() async {
        // Refuse an unconsumed attempt so the dialer fails fast. An attempt
        // whose establish() already consumed the Incoming reports "already
        // consumed"; dropping the in-flight Accepting aborts that handshake.
        try? await incoming.refuse()
    }
}
