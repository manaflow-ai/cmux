import Foundation

extension AgentPaneReplyPaths {
    /// Whether `text` is a bare file name a reply wrote (`next-sync.py`, `foo.test.ts`): no folder,
    /// not from home, not a URL, and an extension with a letter, so `1.5` and versions never are.
    static func isBareName(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 255, !text.contains("/"), !text.hasPrefix("~"), !text.contains(":") else { return false }
        let ext = (text as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 12 && ext.contains(where: \.isLetter) && (text as NSString).deletingPathExtension.count > 0
    }
}

extension AgentPaneModel {
    /// Bare file names (`next-sync.py`) that are not in the chat's folder itself: the file of that
    /// name inside the roots (``AgentPaneReplyLinks/findByName``), checked like any path written
    /// out in full (deny list, roots, symlinks). One search for every name of a reply.
    func resolveNames(_ texts: [String], resolver: AgentPaneReplyPaths) async -> [String: AgentPaneReplyPaths.Resolved] {
        let names = Array(Set(texts.filter(AgentPaneReplyPaths.isBareName)))
        guard !names.isEmpty, !resolver.roots.isEmpty else { return [:] }
        let found = await replyLinks.findByName(names, resolver.roots)
        var out: [String: AgentPaneReplyPaths.Resolved] = [:]
        for name in names {
            // Best first (``AgentPaneReplyLinks/findByName``): the first that passes every check wins.
            for candidate in found[name] ?? [] {
                guard (candidate as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame,
                      let resolved = resolver.resolve(candidate), resolved.place == .root, !resolved.isFolder else { continue }
                out[name] = resolved
                break
            }
        }
        return out
    }

    /// What the person is told when a path chip did not open, or nil when nothing needs saying
    /// (they declined the outside-the-project sheet, or the click was not theirs). Never says
    /// whether a denied file exists.
    static func openFailureNotice(_ error: AgentPaneReplyError, path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        switch error {
        case .pathInvalid:
            let format = String(localized: "agentPane.link.notFound", defaultValue: "Can't find %@ in this chat's folder.", bundle: .module)
            return String(format: format, name)
        case .pathDenied:
            return String(localized: "agentPane.link.denied", defaultValue: "This file may hold secrets, so cmux doesn't open it from a chat.", bundle: .module)
        case .pathOutsideRoots:
            return String(localized: "agentPane.link.outside", defaultValue: "This file is outside the chat's folders.", bundle: .module)
        case .openFailed:
            let format = String(localized: "agentPane.link.openFailed", defaultValue: "Couldn't open %@.", bundle: .module)
            return String(format: format, name)
        default:
            return nil
        }
    }
}
