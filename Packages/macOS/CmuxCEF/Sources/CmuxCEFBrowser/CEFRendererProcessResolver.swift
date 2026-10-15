import CmuxBrowser
import Darwin
import Foundation

/// Maps Chromium's renderer client ids to the helper processes that run them.
///
/// Each renderer helper is a child of the app started with
/// `--renderer-client-id=<id>`; `CEFBrowser.rendererClientIDs()` names the
/// ids of a page's frames. The resolver reads the app's children with
/// `proc_listchildpids` and their argv once per pid (argv never changes for
/// a process), so a memory budget sample costs one child listing.
@MainActor
final class CEFRendererProcessResolver {
    private let parent: pid_t
    private let children: (pid_t) -> [Int32]
    private let arguments: (Int32) -> [String]
    /// Renderer client id per helper pid; nil for a child that is not a renderer.
    private var clientIDs: [Int32: Int32?] = [:]

    /// - Parameters:
    ///   - parent: The app process.
    ///   - children: Lists a process's children; injectable for tests.
    ///   - arguments: Reads a process's argv; injectable for tests.
    init(
        parent: pid_t = getpid(),
        children: @escaping (pid_t) -> [Int32] = CEFRendererProcessResolver.childPIDs(of:),
        arguments: @escaping (Int32) -> [String] = ChromiumHelperIdentity.arguments(pid:)
    ) {
        self.parent = parent
        self.children = children
        self.arguments = arguments
    }

    /// The helper pid running a renderer client id, or nil when none is live.
    func pid(forRendererClientID clientID: Int32) -> Int32? {
        let live = children(parent)
        let liveSet = Set(live)
        clientIDs = clientIDs.filter { liveSet.contains($0.key) }
        for pid in live {
            if clientIDs[pid] == nil {
                let argv = arguments(pid)
                let id = Self.rendererClientID(argv)
                // A helper forked a moment ago may still show the app's argv: retry it next time.
                if id != nil || ChromiumHelperIdentity.parse(argv) != nil {
                    clientIDs[pid] = .some(id)
                }
            }
            if clientIDs[pid] == .some(clientID) { return pid }
        }
        return nil
    }

    /// The `--renderer-client-id` of a renderer helper's argv; nil for any
    /// other process, including extension renderers.
    nonisolated static func rendererClientID(_ arguments: [String]) -> Int32? {
        guard let identity = ChromiumHelperIdentity.parse(arguments), identity.processType == "renderer",
              !identity.isExtension else { return nil }
        let prefix = "--renderer-client-id="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Int32(argument.dropFirst(prefix.count))
    }

    nonisolated static func childPIDs(of pid: pid_t) -> [Int32] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
    }
}
