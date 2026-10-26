/// cmux's copy of the Chromium host's helper processes and of each page's
/// renderer clients, kept from the host's HELPER_START, HELPER_EXIT and
/// RENDERER_CLIENTS frames (`CEFShim/src/chromium_host_helpers.h`).
///
/// In host mode the helpers are the host's children, not the app's, so
/// ``ChromiumHelperProcess/list(parent:)`` and ``CEFChildProcessMonitor`` see
/// none of them. The host watches them the way the in-process monitor does
/// and pushes each change; reads here never cross the wire (the `mirror`
/// class of plans/cmux-next/chromium-host-ops.json). As in Chrome, the
/// browser process is the one that sees its children end
/// (content/public/browser/browser_child_process_observer.h,
/// `BrowserChildProcessKilled` / `BrowserChildProcessCrashed`).
final class ChromiumHostProcessMirror {
    /// A host that sends more is broken; the rest is dropped and counted.
    static let helperLimit = 1_024
    static let browserLimit = 1_024
    static let clientsPerBrowserLimit = 64

    private var helpers: [Int32: ChromiumHelperProcess] = [:]
    private var identities: [Int32: CEFHelperIdentity] = [:]
    private var clientsByBrowser: [Int32: [Int32]] = [:]
    /// Frames this mirror could not use (bad payload, over a limit).
    private(set) var refusedFrames = 0

    init() {}

    /// The host's live helpers, by pid.
    var processes: [ChromiumHelperProcess] {
        helpers.values.sorted { $0.pid < $1.pid }
    }

    /// Renderer client ids hosting `browser`'s frames (empty when unknown).
    func rendererClients(browser: Int32) -> [Int32] {
        clientsByBrowser[browser] ?? []
    }

    /// `debug.chromium_host` `helpers`: each helper's pid and kind, and the
    /// pids that render the host's pages (the tab process list in host mode).
    var report: [String: Any] {
        var rendererPIDs: [Int32: Int32] = [:]
        let list = processes.map { helper -> [String: Any] in
            var entry: [String: Any] = ["pid": Int(helper.pid)]
            switch helper.kind {
            case .renderer(let client):
                rendererPIDs[client] = helper.pid
                entry["kind"] = "renderer"
                entry["renderer_client_id"] = Int(client)
            case .extensionRenderer: entry["kind"] = "extension"
            case .gpu: entry["kind"] = "gpu"
            case .network: entry["kind"] = "network"
            case .utility: entry["kind"] = "utility"
            case .other: entry["kind"] = "other"
            }
            return entry
        }
        let clients = Set(clientsByBrowser.values.joined()).sorted()
        return ["processes": list, "renderer_clients": clients.map { Int($0) },
                "page_renderer_pids": clients.compactMap { rendererPIDs[$0] }.map { Int($0) },
                "refused_frames": refusedFrames]
    }

    /// Applies one host frame; returns the helper exit it reports, if any.
    /// Other kinds are ignored.
    @discardableResult
    func apply(_ frame: ChromiumHostFrame) -> CEFChildProcessMonitor.Exit? {
        switch frame.kind {
        case .helperStart:
            started(frame)
            return nil
        case .helperExit:
            return ended(frame)
        case .rendererClients:
            clients(frame)
            return nil
        default:
            return nil
        }
    }

    /// The host ended: its helpers end with it, and their exits are its own.
    func reset() {
        helpers = [:]
        identities = [:]
        clientsByBrowser = [:]
    }

    private func started(_ frame: ChromiumHostFrame) {
        let pid = frame.v[0]
        guard pid > 0, let identity = Self.identity(of: frame, isExtension: frame.v[2] != 0),
              helpers[pid] != nil || helpers.count < Self.helperLimit else {
            refusedFrames += 1
            return
        }
        identities[pid] = identity
        helpers[pid] = ChromiumHelperProcess(pid: pid, kind: ChromiumHelperProcess.kind(of: identity, rendererClientID: frame.v[1]))
    }

    private func ended(_ frame: ChromiumHostFrame) -> CEFChildProcessMonitor.Exit? {
        let pid = frame.v[0]
        helpers.removeValue(forKey: pid)
        let known = identities.removeValue(forKey: pid)
        // The exit names the helper itself, so one whose start this mirror missed is still reported.
        guard pid > 0, let identity = known ?? Self.identity(of: frame, isExtension: frame.v[4] != 0) else {
            refusedFrames += 1
            return nil
        }
        return CEFChildProcessMonitor.Exit(pid: pid, processType: identity.processType, subType: identity.subType,
                                           isExtension: identity.isExtension, status: frame.v[1])
    }

    private func clients(_ frame: ChromiumHostFrame) {
        let browser = frame.v[0]
        let count = Int(frame.v[1])
        guard count >= 0, count <= Self.clientsPerBrowserLimit, frame.payload.count == count * 4,
              clientsByBrowser[browser] != nil || clientsByBrowser.count < Self.browserLimit else {
            refusedFrames += 1
            return
        }
        var ids: [Int32] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            var value: UInt32 = 0
            for byte in 0..<4 { value |= UInt32(frame.payload[index * 4 + byte]) << UInt32(8 * byte) }
            ids.append(Int32(bitPattern: value))
        }
        clientsByBrowser[browser] = ids.isEmpty ? nil : ids
    }

    /// `type` or `type\nsub type` from a helper frame's payload.
    private static func identity(of frame: ChromiumHostFrame, isExtension: Bool) -> CEFHelperIdentity? {
        let parts = frame.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let type = parts.first, !type.isEmpty else { return nil }
        let subType = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return CEFHelperIdentity(processType: String(type), subType: subType, isExtension: isExtension)
    }
}
