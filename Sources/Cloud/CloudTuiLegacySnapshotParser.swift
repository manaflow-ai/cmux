import Foundation

/// Resolves a public `term_…` resource id to the numeric surface id used by
/// cmux-tui's byte attach protocol.
///
/// The public session snapshot intentionally hides numeric implementation ids;
/// the legacy `list-workspaces` compatibility snapshot carries both identities
/// at the terminal tab boundary. Keeping this translation here prevents the
/// native pane from depending on the TUI's renderer or public-id internals.
struct CloudTuiLegacySnapshotParser: Sendable {
    /// Finds a numeric surface in the result of the private
    /// `resolve-terminal` command. A null or malformed response returns nil;
    /// callers that need to distinguish those cases can use ``resolvedSurface(from:)``.
    func resolvedSurfaceID(from data: Data) -> UInt64? {
        if case let .surface(surface) = resolvedSurface(from: data) {
            return surface
        }
        return nil
    }

    /// Decodes the resolver response without conflating a valid zero-view
    /// terminal (`surface:null`) with malformed or failed data.
    func resolvedSurface(from data: Data) -> CloudTuiResolvedSurface {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [String: Any])?["data"] as? [String: Any]
                  ?? root as? [String: Any] else {
            return .malformed
        }
        guard object.keys.contains("surface") else { return .malformed }
        if object["surface"] is NSNull { return .noPlacement }
        guard let surface = number(from: object["surface"]) else { return .malformed }
        return .surface(surface)
    }

    /// Reads the protocol integer from an `identify` response envelope. A
    /// malformed, failed, fractional, or non-boolean response returns `nil` so
    /// a caller cannot infer compatibility from an unreliable value.
    func protocolVersion(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              positiveInteger(from: object["id"]) == 1,
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(),
              ok.boolValue,
              let data = object["data"] as? [String: Any],
              let number = data["protocol"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let type = String(cString: number.objCType)
        switch type {
        case "c", "s", "i", "l", "q":
            let value = number.int64Value
            return value >= 0 && value <= Int64(Int.max) ? Int(value) : nil
        case "C", "S", "I", "L", "Q":
            let value = number.uint64Value
            return value <= UInt64(Int.max) ? Int(value) : nil
        default:
            return nil
        }
    }

    /// Finds the numeric surface backing `terminalID` in a legacy tree payload.
    func surfaceID(from data: Data, terminalID: String) -> UInt64? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [String: Any])?["data"] as? [String: Any]
                  ?? root as? [String: Any] else {
            return nil
        }
        return surfaceIDs(from: object, terminalIDs: [terminalID])[terminalID]
    }

    /// Finds the numeric surface backing `terminalID` in an already-decoded tree.
    func surfaceID(from object: [String: Any], terminalID: String) -> UInt64? {
        surfaceIDs(from: object, terminalIDs: [terminalID])[terminalID]
    }

    /// Resolves many terminal identities in one compatibility-tree traversal.
    ///
    /// A refresh can own several native projections of one machine. Walking
    /// the workspace/screen/pane/tab hierarchy once keeps the legacy fallback
    /// O(number of tree records + number of requested terminals), rather than
    /// rescanning the same tree for every pane.
    func surfaceIDs(
        from object: [String: Any],
        terminalIDs: Set<String>
    ) -> [String: UInt64] {
        guard !terminalIDs.isEmpty else { return [:] }
        var resolved: [String: UInt64] = [:]
        let workspaces = object["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            let screens = workspace["screens"] as? [[String: Any]] ?? []
            for screen in screens {
                let panes = screen["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let tabs = pane["tabs"] as? [[String: Any]] ?? []
                    for tab in tabs {
                        guard let number = number(from: tab["surface"]) else { continue }
                        for key in [
                            "terminal_resource_id",
                            "tab_resource_id",
                            "content_resource_id",
                            "terminal_id",
                        ] {
                            guard let candidate = tab[key] as? String,
                                  terminalIDs.contains(candidate),
                                  resolved[candidate] == nil else { continue }
                            resolved[candidate] = number
                        }
                    }
                }
            }
        }
        return resolved
    }

    /// Resolves many terminal identities from a JSON or response-envelope
    /// payload in one tree walk.
    func surfaceIDs(from data: Data, terminalIDs: Set<String>) -> [String: UInt64] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [String: Any])?["data"] as? [String: Any]
                  ?? root as? [String: Any] else {
            return [:]
        }
        return surfaceIDs(from: object, terminalIDs: terminalIDs)
    }

    private func number(from value: Any?) -> UInt64? {
        if let number = positiveInteger(from: value) { return number }
        if let string = value as? String {
            return UInt64(string).flatMap { $0 > 0 ? $0 : nil }
        }
        return nil
    }

    /// Converts a JSON number to a positive integer without accepting booleans
    /// or floating-point values that NSNumber would otherwise coerce.
    private func positiveInteger(from value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let type = String(cString: number.objCType)
        switch type {
        case "c", "s", "i", "l", "q":
            let signed = number.int64Value
            return signed > 0 ? UInt64(signed) : nil
        case "C", "S", "I", "L", "Q":
            let unsigned = number.uint64Value
            return unsigned > 0 ? unsigned : nil
        default:
            // Floating-point JSON values (including 1.5) are rejected
            // rather than rounded into a potentially different identifier.
            return nil
        }
    }
}
