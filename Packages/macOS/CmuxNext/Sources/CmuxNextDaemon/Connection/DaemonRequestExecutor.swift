import Foundation
import os

/// Executes typed wire requests on one captured transport, without rebinding or admission.
///
/// A typed request is a v12 command, so once the connection holds `ipc-frames-v2` it goes as a REQUEST frame
/// when the daemon listed its method as answered on frames (``FramedRequests``); its reply is the same JSON
/// either way. Every other command stays a line, so no request is refused for its encoding and none is sent
/// twice. Other callers of the transport (v2 resource envelopes, raw lines) stay lines.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    /// `opening`: the stream `request` opens (`attach-surface {stream}`); framed, its header names it.
    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?,
                                   opening: AttachStreamHandle? = nil) async throws -> R.Response {
        #if DEBUG
        Self.checkNoStandIn(request)
        #endif
        let response = try await transport.request(cmd: R.commandName, timeout: timeout, framed: true,
                                                   opening: opening) { id in
            let line = try WireCoding.encodeRequest(request, id: id)
            // Rule (b): a request that names a stand-in is never sent. A create resolves its target first (the DEBUG
            // check above stops one that did not); any other pane verb on a pane still opening fails here, at once,
            // with no daemon round trip, and its refusal shows (``PaneNotReady``, `DaemonService.onPaneNotReady`).
            if Self.mayNameStandIn(line), let leak = Self.standInReference(inLine: line) {
                throw PaneNotReady(command: R.command, reference: leak)
            }
            return line
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response)
    }

    /// The decimal prefix every stand-in id starts with (2^62 = 4611686018427387904; stand-ins count up from it), so a
    /// line without it names no stand-in: one byte scan per request, a JSON parse only on a hit.
    private static let standInPrefix = Data("4611686018427".utf8)

    static func mayNameStandIn(_ line: Data) -> Bool { line.range(of: standInPrefix) != nil }

    /// ``standInReference(in:)`` for an encoded request line.
    static func standInReference(inLine line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) else { return nil }
        return standInReference(in: object, key: nil)
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.stand-in")

    /// DEBUG, rule (b) of the P0 2026-10-30: a request names no stand-in. The creates that resolve their target with
    /// `DaemonStore.daemonTarget(_:)` (every terminal-starting request: new-tab, split, new-pane, new-pane-right,
    /// new-row) stop here; any other request that still names one is logged, not stopped: those pane verbs (zoom,
    /// rename, swap, a New Tab page on a pending pane) do not wait for their pane yet
    /// ("unknown pane"), as before this check; any other request naming one is refused before it is sent
    /// (``PaneNotReady``; follow-up: one seam where every pane verb waits for its pane).
    static func checkNoStandIn<R: DaemonRequest>(_ request: R) {
        guard let leak = standInReference(in: request) else { return }
        if R.self is any TerminalSpawningRequest.Type {
            // crash-allow: DEBUG-only invariant check (rule b): these creates resolve their target before they send
            assertionFailure("\(R.command) names stand-in \(leak): resolve it with DaemonStore.daemonTarget(_:) first")
        } else {
            logger.info("\(R.command, privacy: .public) names stand-in \(leak, privacy: .public); refused locally (PaneNotReady)")
        }
    }
    #endif

    /// The first pane or surface reference of `request` that is a stand-in's id (a pending create's pane handle or
    /// tab surface, both at or above ``ProvisionalPane/firstHandle``; no daemon id ever is), as `key=value`; nil when
    /// none is. The daemon does not know a stand-in: a command naming one is refused ("unknown pane"), and the person's
    /// create vanished (P0 2026-10-30, the second quick Cmd-D).
    static func standInReference<R: Encodable>(in request: R) -> String? {
        guard let data = try? JSONEncoder().encode(request), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return standInReference(in: object, key: nil)
    }

    private static func standInReference(in value: Any, key: String?) -> String? {
        if let dictionary = value as? [String: Any] {
            for (name, child) in dictionary.sorted(by: { $0.key < $1.key }) {
                if let found = standInReference(in: child, key: name) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array { if let found = standInReference(in: child, key: key) { return found } }
            return nil
        }
        guard let key, Self.namesPaneOrSurface(key), let number = value as? NSNumber,
              CFNumberGetType(number) != .charType, number.uint64Value >= ProvisionalPane.firstHandle else { return nil }
        return "\(key)=\(number)"
    }

    /// Keys that carry a pane handle or a tab surface on the wire (`pane`, `target_pane`, `surface`, `surfaces`, ...).
    private static func namesPaneOrSurface(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.contains("pane") || key.contains("surface") || key == "target" || key == "anchor"
    }
}
