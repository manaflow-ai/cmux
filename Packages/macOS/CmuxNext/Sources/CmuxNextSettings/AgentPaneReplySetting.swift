/// `agentPane.links.outsideRoots` and `agentPane.images.remote` in cmux.json: what an agent
/// reply may open or load beyond the session's own folders (decisions D4 and D5,
/// plans/cmux-next/agent-pane-gaps.md). The host reads them on every request, so a change
/// applies to the next click.
///
/// `outsideRoots` (default `open`): a path chip outside the session's folders opens on its click
/// like a path inside them (`open`), asks before it opens (`confirm`), or draws as plain text
/// (`text`).
/// A path on the deny list (`~/.ssh`, keys, `.env` files) is always plain text.
///
/// `remote` (default `click`): a web image in a reply shows a placeholder and loads after a
/// click (`click`), never loads (`never`), or loads at once (`always`). Every load goes through
/// the host's fetch rules (https only, no private or loopback address, size and time caps, no
/// cookies); `always` changes only when it starts.
public nonisolated struct AgentPaneReplySetting: Sendable, Hashable {
    public enum OutsideRoots: String, Sendable, Hashable, CaseIterable {
        case confirm, text, open
    }

    public enum RemoteImages: String, Sendable, Hashable, CaseIterable {
        case click, never, always
    }

    public var outsideRoots: OutsideRoots
    public var remoteImages: RemoteImages

    public static let fallback = AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click)

    public init(outsideRoots: OutsideRoots, remoteImages: RemoteImages) {
        self.outsideRoots = outsideRoots
        self.remoteImages = remoteImages
    }

    static let outsideRootsPath = ["agentPane", "links", "outsideRoots"]
    static let remoteImagesPath = ["agentPane", "images", "remote"]

    static func parse(_ root: JSONValue) -> (AgentPaneReplySetting, [SettingsDiagnostic]) {
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        guard let pane = root["agentPane"] else { return (setting, []) }
        guard case .object = pane else {
            return (setting, [SettingsDiagnostic(kind: .invalidValue, path: "agentPane", message: "expected an object")])
        }
        func choice<Value: RawRepresentable>(_ path: [String], _ type: Value.Type) -> Value? where Value.RawValue == String,
                                                                                               Value: CaseIterable {
            var value: JSONValue? = root
            for key in path { value = value?[key] }
            guard let value else { return nil }
            if case .string(let raw) = value, let parsed = Value(rawValue: raw) { return parsed }
            let allowed = Value.allCases.map(\.rawValue).joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                  message: "expected one of \(allowed)"))
            return nil
        }
        for (key, child) in [("links", pane["links"]), ("images", pane["images"])] {
            if let child, child.objectValue == nil {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "agentPane.\(key)", message: "expected an object"))
            }
        }
        if let value = choice(outsideRootsPath, OutsideRoots.self) { setting.outsideRoots = value }
        if let value = choice(remoteImagesPath, RemoteImages.self) { setting.remoteImages = value }
        return (setting, diagnostics)
    }
}

nonisolated extension CmuxConfigSnapshot {
    /// `agentPane.links.outsideRoots` and `agentPane.images.remote` (its diagnostics join the
    /// snapshot's in `parse`).
    public var agentPaneReplies: AgentPaneReplySetting { AgentPaneReplySetting.parse(root).0 }
}
