import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        #if DEBUG
        // crash-allow: DEBUG-only invariant check (rule b of the P0 2026-10-30): a stand-in id never leaves for the daemon
        if let leak = Self.standInReference(in: request) {
            assertionFailure("\(R.command) names stand-in \(leak): resolve it with DaemonStore.daemonTarget(_:) first")
        }
        #endif
        let response = try await transport.request(cmd: R.command, timeout: timeout) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response.line)
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
