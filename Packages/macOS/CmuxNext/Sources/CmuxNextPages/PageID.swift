public import Foundation
import Synchronization

/// Page ids and their trust (coordinator rule from the P8 review): a page id is its origin host
/// (`cmux-page://<id>`), and a first-party host inherits first-party access (`cmux.agent` reaches
/// acpmux). So the host keeps one table of first-party ids, every `cmux.` id is first party, and no
/// app manifest or third-party page can claim or be served under one. The browser lead's CEF
/// scheme registration reads the same table.
public nonisolated struct PageID {
    public nonisolated init() {}
    /// First-party pages the app ships.
    public static let firstParty: Set<String> = [
        "cmux.history", "cmux.apps", "cmux.settings", "cmux.cloud", "cmux.agent", "cmux.keybindings",
        "cmux.diff", "cmux.markdown", "cmux.icon-picker", "cmux.passwords", "cmux.editor", "cmux.chief-inspector",
    ]

    /// Whether `id` is a first-party page in the table (it gets first-party access).
    public static func isFirstParty(_ id: String) -> Bool {
        firstParty.contains(id.lowercased())
    }

    /// Whether no app may use `id`: a first-party id, or anything in the reserved `cmux.` namespace
    /// (including ids no shipped page uses yet, such as `cmux.agentx`).
    public static func isReserved(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return isFirstParty(lowered) || lowered == "cmux" || lowered.hasPrefix("cmux.")
    }

    private static let registeredRoots = Mutex<[String: URL]>([:])

    /// Names the bundled root of a first-party page whose files live in another module's resource
    /// bundle (`cmux.agent` in CmuxNextAgentPane). Only a first-party id, only once: the first
    /// registration wins, so a later caller cannot move a first-party origin to other files. An
    /// app manifest has no Swift code and cannot call it.
    public static func registerBundledRoot(_ root: URL, for id: String) {
        guard isFirstParty(id) else { return }
        registeredRoots.withLock { roots in
            if roots[id.lowercased()] == nil { roots[id.lowercased()] = root }
        }
    }

    /// The bundled root registered for `id`, else nil.
    public static func bundledRoot(for id: String) -> URL? {
        registeredRoots.withLock { $0[id.lowercased()] }
    }

    /// Why an app page was refused.
    public enum Refusal: Error, Sendable, Equatable {
        /// The id is a first-party id or in the reserved `cmux.` namespace.
        case reservedID(String)
        /// The page asks for a `cmux.` op namespace (first-party ops are reached through scopes).
        case reservedNamespace(String)
        /// The id is not a reverse-DNS app id a URL host can carry.
        case invalidID(String)
    }
}

public extension PageDescriptor {
    /// A page an app manifest declares (third party or first-party app code outside the host
    /// table). Its id must be the app's reverse-DNS id, never a first-party id, and its namespaces
    /// must be its own; it gets no native ops and runs no registry actions.
    static func appPage(id: String, resource: String, namespaces: [String]) throws(PageID.Refusal) -> PageDescriptor {
        guard !PageID.isReserved(id) else { throw .reservedID(id) }
        let host = id.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { throw .invalidID(id) }
        if let reserved = namespaces.first(where: { PageID.isReserved($0) || !$0.lowercased().hasPrefix(host + ".") }) {
            throw .reservedNamespace(reserved)
        }
        return PageDescriptor(id: host, resource: resource, namespaces: namespaces)
    }
}
