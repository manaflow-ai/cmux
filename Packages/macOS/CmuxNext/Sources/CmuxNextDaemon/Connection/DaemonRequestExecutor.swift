import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        let response = try await transport.request(cmd: R.command, timeout: timeout) { id in
            let line = try WireCoding.encodeRequest(request, id: id)
            // Rule (b): a request that names a stand-in is never sent, from any sender. The creates that know how
            // resolve their target to the daemon's pane first (`DaemonStore.daemonTarget`); anything still naming a pane
            // that is opening fails here, at once, with no daemon round trip, and the person sees why
            // (``PaneNotReady``; `DaemonService.ended` shows it once).
            if Self.mayNameStandIn(line), let leak = Self.standInReference(inLine: line) {
                throw PaneNotReady(command: R.command, reference: leak)
            }
            return line
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response.line)
    }

    /// Whether `line` may name a stand-in: it holds a decimal number of at least 2^62 = 4611686018427387904 (every stand-in
    /// lives there: a split's or New Terminal Tab's pane and surface from 2^62, Cmd-N's workspace pane from 2^62 + 2^61;
    /// no daemon id does). One byte pass with no allocation; a JSON parse (``standInReference(inLine:)``) only on a hit.
    static func mayNameStandIn(_ line: Data) -> Bool {
        let floor = Self.standInFloor
        var length = 0
        // While the run has 19 digits or fewer: how it compares with the floor's prefix of the same length.
        var order = 0 // -1 below, 0 equal so far, 1 above
        for byte in line {
            guard byte >= 0x30, byte <= 0x39 else {
                if length > 19 || (length == 19 && order >= 0) { return true }
                length = 0
                order = 0
                continue
            }
            if length < floor.count, order == 0 { order = byte < floor[length] ? -1 : byte > floor[length] ? 1 : 0 }
            length += 1
        }
        return length > 19 || (length == 19 && order >= 0)
    }

    /// 2^62 in decimal, the lowest stand-in id.
    private static let standInFloor = Array("4611686018427387904".utf8)

    /// ``standInReference(in:)`` for an encoded request line.
    static func standInReference(inLine line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) else { return nil }
        return standInReference(in: object, key: nil)
    }

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
