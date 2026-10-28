public import Darwin
import Foundation
import CmuxNextCompat
public import CmuxNextWakeups

/// One Chromium helper process and what it does, read from its argv (`--type`,
/// `--utility-sub-type`, `--extension-process`, `--renderer-client-id`).
/// Listing reads the children of the helpers' parent once (the app in process,
/// the Chromium Host in host mode: ``ChromiumHelperParent``); argv is cached
/// per PID (it never changes for a process).
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

        #if DEBUG || CMUX_BENCH_HOOKS
        /// The kind as `debug.webui` names it: `renderer`, `extension_renderer`, `gpu`, `network`,
        /// `utility` or `other`.
        public var name: String {
            switch self {
            case .renderer: "renderer"
            case .extensionRenderer: "extension_renderer"
            case .gpu: "gpu"
            case .network: "network"
            case .utility: "utility"
            case .other: "other"
            }
        }

        /// A tab renderer's client id; nil for every other kind.
        public var rendererClientID: Int32? {
            if case .renderer(let clientID) = self { clientID } else { nil }
        }
        #endif
    }

    public var pid: Int32
    public var kind: Kind

    public init(pid: Int32, kind: Kind) {
        self.pid = pid
        self.kind = kind
    }

    /// The live Chromium helpers of `parent` (``ChromiumHelperParent/pid``); none for nil, host mode with no host.
    public static func list(parent: pid_t?) -> [ChromiumHelperProcess] {
        guard let parent else { return [] }
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

    /// Each live tab renderer of `parent` with its counters now (the Energy Saver's busy hidden pages).
    /// Blocking syscalls (``ProcessUsage/sample(_:)`` per renderer): call it off the main actor.
    public static func tabRendererUsage(parent: pid_t?) -> [(renderer: ProcessUsage.Renderer, usage: ProcessUsage)] {
        list(parent: parent).compactMap { helper -> (renderer: ProcessUsage.Renderer, usage: ProcessUsage)? in
            guard case .renderer(let client) = helper.kind, let usage = ProcessUsage.sample(helper.pid) else { return nil }
            return (renderer: ProcessUsage.Renderer(pid: helper.pid, clientID: client), usage: usage)
        }
    }

    /// The kind of a helper from its argv; nil for a process that is not a
    /// Chromium helper (or whose argv is not readable yet).
    public static func classify(_ arguments: [String]) -> Kind? {
        guard let identity = CEFHelperIdentity.parse(arguments) else { return nil }
        switch identity.processType {
        case "renderer":
            if identity.isExtension { return .extensionRenderer }
            return identity.rendererClientID.map { .renderer(clientID: $0) } ?? .other
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
        // SAFETY: a NULL buffer of size 0 only asks for the count.
        let count = unsafe proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let room = Int32(pids.count * MemoryLayout<pid_t>.size)
        // SAFETY: the kernel writes at most `room` bytes, the array's size, into its buffer during the call.
        let filled = unsafe proc_listchildpids(pid, &pids, room)
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
    }
}
