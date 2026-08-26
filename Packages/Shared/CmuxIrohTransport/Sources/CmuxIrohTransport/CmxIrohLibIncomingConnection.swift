import Foundation
import IrohLib

/// One un-handshaken incoming iroh connection attempt.
///
/// ``establish()`` performs the server-side handshake (`Incoming.accept`,
/// ALPN validation, handshake completion) that used to run inline in the
/// endpoint's accept path. Once `accept()` consumes the `Incoming`, the
/// attempt cannot be aborted from Swift: `refuse()` reports "already
/// consumed" and the bindings do not propagate task cancellation into the
/// driver. The attempt therefore resolves only when the driver's own
/// handshake/idle timeout bounds it, and ``CmxIrohEndpointServer`` keeps
/// the admission slot occupied until that resolution, so a stalled attempt
/// can only ever cost its own admission slot.
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
