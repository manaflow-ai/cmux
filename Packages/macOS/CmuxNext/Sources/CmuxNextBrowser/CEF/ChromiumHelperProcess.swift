public import Darwin
import Foundation
import Synchronization

/// One Chromium helper process of this app and what it does, read from its
/// argv (`--type`, `--utility-sub-type`, `--extension-process`,
/// `--renderer-client-id`). Listing reads the app's children once; argv is
/// cached per PID (it never changes for a process).
public nonisolated struct ChromiumHelperProcess: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A tab renderer; `clientID` matches the tab's frames.
        case renderer(clientID: Int32)
        /// An extension's renderer (background page, service worker).
        case extensionRenderer
        case gpu
        /// The network service utility process.
        case network
        /// Other utility processes (storage, audio, data decoder, ...).
        case utility
        case other
    }

    public var pid: Int32
    public var kind: Kind

    public init(pid: Int32, kind: Kind) {
        self.pid = pid
        self.kind = kind
    }

    /// The app's live Chromium helpers.
    public static func list(parent: pid_t = getpid()) -> [ChromiumHelperProcess] {
        let children = childPIDs(of: parent)
        let live = Set(children)
        let cached = cache.withLock { cache -> [Int32: Kind] in
            cache = cache.filter { live.contains($0.key) }
            return cache
        }
        var out: [ChromiumHelperProcess] = []
        var learned: [Int32: Kind] = [:]
        for pid in children {
            // Unknown results are not cached: a helper forked a moment ago
            // may not have exec'd yet and still shows the app's argv.
            let kind = cached[pid] ?? classify(CEFHelperIdentity.arguments(pid: pid))
            if let kind {
                if cached[pid] == nil { learned[pid] = kind }
                out.append(ChromiumHelperProcess(pid: pid, kind: kind))
            }
        }
        if !learned.isEmpty { cache.withLock { $0.merge(learned) { $1 } } }
        return out
    }

    /// The kind of a helper from its argv; nil for a process that is not a
    /// Chromium helper (or whose argv is not readable yet).
    public static func classify(_ arguments: [String]) -> Kind? {
        guard let identity = CEFHelperIdentity.parse(arguments) else { return nil }
        switch identity.processType {
        case "renderer":
            if identity.isExtension { return .extensionRenderer }
            let prefix = "--renderer-client-id="
            if let argument = arguments.first(where: { $0.hasPrefix(prefix) }),
               let id = Int32(argument.dropFirst(prefix.count)) {
                return .renderer(clientID: id)
            }
            return .other
        case "gpu-process":
            return .gpu
        case "utility":
            return identity.subType == "network.mojom.NetworkService" ? .network : .utility
        default:
            return .other
        }
    }

    private static let cache = Mutex<[Int32: Kind]>([:])

    private static func childPIDs(of pid: pid_t) -> [Int32] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
    }
}
