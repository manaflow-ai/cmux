import Foundation

/// Translates the small resource-CLI subset used by Cloud terminal creation
/// into the daemon's typed request envelope. Unsupported commands deliberately
/// return nil and keep the compatibility process path until their semantics are
/// migrated and tested.
enum CloudTuiPersistentRequestBuilder {
    struct Request {
        let operation: String
        let params: [String: Any]
        let idempotencyKey: String?
    }

    static func parse(_ arguments: [String]) -> Request? {
        var values = arguments
        while let first = values.first, first.hasPrefix("--") {
            if first == "--json" { values.removeFirst(); continue }
            guard values.count > 1 else { return nil }
            switch first {
            case "--socket", "--idempotency-key", "--correlation-key", "--expected-revision":
                values.removeFirst(2)
            default:
                return nil
            }
        }
        guard !values.isEmpty else { return nil }
        var idempotencyKey: String?
        var correlationKey: String?
        var expectedRevision: String?
        var onExit: String?
        var cwd: String?
        var name: String?
        func consume(_ name: String, _ value: inout String?) {
            guard let index = values.firstIndex(of: name), values.index(after: index) < values.endIndex else { return }
            value = values[values.index(after: index)]
            values.removeSubrange(index...values.index(after: index))
        }
        consume("--idempotency-key", &idempotencyKey)
        consume("--correlation-key", &correlationKey)
        consume("--expected-revision", &expectedRevision)
        consume("--on-exit", &onExit)
        consume("--cwd", &cwd)
        consume("--name", &name)
        guard values.count >= 3 else { return nil }
        let scope = values[0]
        switch scope {
        case "session" where values.count == 3 && values[2] == "snapshot":
            return Request(operation: "session.snapshot", params: [
                "machine": "current", "session": values[1],
            ], idempotencyKey: nil)
        case "workspace" where values.count >= 4 && values[2] == "run":
            let selector = values[1]
            guard let separator = values.firstIndex(of: "--"), separator + 1 < values.count else { return nil }
            let argv = Array(values[(separator + 1)...])
            guard !argv.isEmpty else { return nil }
            var params: [String: Any] = [
                "machine": "current", "session": "current", "workspace": selector,
                "argv": argv,
            ]
            if let correlationKey { params["correlation_key"] = correlationKey }
            if let expectedRevision { params["expected_revision"] = expectedRevision }
            if let onExit { params["on_exit"] = onExit }
            if let cwd { params["cwd"] = cwd }
            if let name { params["name"] = name }
            return Request(operation: "workspace.run", params: params, idempotencyKey: idempotencyKey)
        case "pane" where values.count >= 3:
            let selector = values[1]
            let action = values[2]
            if action == "split" {
                let direction = values.dropFirst(3).first(where: { $0 == "--right" || $0 == "--down" })
                    .map { $0 == "--down" ? "down" : "right" } ?? "right"
                var params: [String: Any] = [
                    "machine": "current", "session": "current", "workspace": "current", "pane": selector,
                    "direction": direction,
                ]
                if let correlationKey { params["correlation_key"] = correlationKey }
                if let expectedRevision { params["expected_revision"] = expectedRevision }
                return Request(operation: "pane.split", params: params, idempotencyKey: idempotencyKey)
            }
            if action == "run", let separator = values.firstIndex(of: "--"), separator + 1 < values.count {
                var params: [String: Any] = [
                    "machine": "current", "session": "current", "workspace": "current", "pane": selector,
                    "argv": Array(values[(separator + 1)...]),
                ]
                if let correlationKey { params["correlation_key"] = correlationKey }
                if let expectedRevision { params["expected_revision"] = expectedRevision }
                if let onExit { params["on_exit"] = onExit }
                if let cwd { params["cwd"] = cwd }
                if let name { params["name"] = name }
                return Request(operation: "pane.run", params: params, idempotencyKey: idempotencyKey)
            }
            return nil
        default:
            return nil
        }
    }
}
