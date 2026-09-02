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
    /// `resolve-terminal` command. A null surface means the terminal has no
    /// current placement and callers should fall back to the legacy tree.
    func resolvedSurfaceID(from data: Data) -> UInt64? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return nil
        }
        return number(from: object["surface"])
    }

    /// Finds the numeric surface backing `terminalID` in a legacy tree payload.
    func surfaceID(from data: Data, terminalID: String) -> UInt64? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = (root as? [String: Any])?["data"] as? [String: Any]
                  ?? root as? [String: Any] else {
            return nil
        }
        return surfaceID(from: object, terminalID: terminalID)
    }

    /// Finds the numeric surface backing `terminalID` in an already-decoded tree.
    func surfaceID(from object: [String: Any], terminalID: String) -> UInt64? {
        let workspaces = object["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            let screens = workspace["screens"] as? [[String: Any]] ?? []
            for screen in screens {
                let panes = screen["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let tabs = pane["tabs"] as? [[String: Any]] ?? []
                    for tab in tabs {
                        let matches = (tab["terminal_resource_id"] as? String) == terminalID
                            || (tab["tab_resource_id"] as? String) == terminalID
                            || (tab["content_resource_id"] as? String) == terminalID
                            || (tab["terminal_id"] as? String) == terminalID
                        guard matches else { continue }
                        if let number = number(from: tab["surface"]) { return number }
                    }
                }
            }
        }
        return nil
    }

    private func number(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            guard number.int64Value > 0 else { return nil }
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string).flatMap { $0 > 0 ? $0 : nil }
        }
        return nil
    }
}
