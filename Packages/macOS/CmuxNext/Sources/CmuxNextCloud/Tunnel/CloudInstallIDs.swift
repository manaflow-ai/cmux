public import CmuxNextWakeups

/// This Mac's install ids (``CloudDeviceID``): the build's own (`cloud-next/device-id`), which names this Mac in
/// its tabs and window records (`install:<id>`) whichever Cloud backend a launch selected, and the selected
/// backend's (`cloud-next/<namespace>/device-id`), which its tunnel enrolls. #35284 kept only the backend's, so a
/// tagged build's next launch named this Mac anew and its saved tabs said "This chat belongs to another machine".
///
/// ```swift
/// let ids = CloudInstallIDs(machine: base, backend: scoped, work: work)
/// let host = try ids.machine.loadNow()  // this Mac in its tabs
/// let tunnel = try ids.backend.loadNow() // the tunnel's device
/// ```
@MainActor
public final class CloudInstallIDs {
    /// This Mac's id, the build's own.
    public let machine: CloudDeviceID
    /// The selected backend's id.
    public let backend: CloudDeviceID
    private let machinePaths: CloudPaths
    private let work: BackgroundWork
    private var others: Set<String>?

    /// Makes the ids; it reads nothing yet.
    ///
    /// - Parameters:
    ///   - machine: the build's Cloud folder.
    ///   - backend: the selected backend's folder (``machine`` itself for a launch on legacy storage).
    ///   - work: the app's blocking-work lanes.
    public init(machine: CloudPaths, backend: CloudPaths, work: BackgroundWork) {
        self.machine = CloudDeviceID(paths: machine, work: work)
        self.backend = CloudDeviceID(paths: backend, work: work)
        machinePaths = machine
        self.work = work
    }

    /// Starts the reads off the main thread (Cloud start): both ids, and ``backendIDs()``'s.
    ///
    /// - Parameter loaded: runs on the main actor with the backends' ids once they are read.
    public func preload(loaded: @escaping @MainActor (Set<String>) -> Void = { _ in }) {
        machine.preload()
        backend.preload()
        guard others == nil else { return loaded(others ?? []) }
        let paths = machinePaths, work = work
        // task-owner: CloudInstallIDs; one bounded directory read at Cloud start.
        Task { [weak self] in
            let ids = (try? await work.run(.userVisible, mayBlock: .files) { Set(paths.backendDeviceIDs()) }) ?? []
            guard let self else { return }
            if others == nil { others = ids }
            loaded(others ?? ids)
        }
    }

    /// Every id launches on other backends named this Mac with (#35284): a tab, a window record or a closed
    /// item saved under one is this Mac's. The kept set once ``preload(loaded:)``'s read ended; before that a
    /// read on the calling thread (the same accepted one-time read as ``CloudDeviceID/loadNow()``).
    ///
    /// - Returns: every `device-id` of a folder under the build's Cloud folder.
    public func backendIDs() -> Set<String> {
        if let others { return others }
        let ids = Set(machinePaths.backendDeviceIDs())
        others = ids
        return ids
    }

    /// The window id of a window record `recorded` (`install/window`) saved under one of `installs`, else nil.
    public static func windowID(_ recorded: String, installs: [String]) -> String? {
        installs.first { recorded.hasPrefix($0 + "/") }.map { String(recorded.dropFirst($0.count + 1)) }
    }

    /// This Mac's ids: ``machine``'s first (when read), then every other backend's.
    public func all() -> [String] {
        let current = try? machine.loadNow()
        return (current.map { [$0] } ?? []) + backendIDs().subtracting(current.map { [$0] } ?? []).sorted()
    }
}
