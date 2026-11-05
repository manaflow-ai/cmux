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
    }

    /// Starts both reads off the main thread (Cloud start).
    public func preload() {
        machine.preload()
        backend.preload()
    }

    /// The ids launches on other backends named this Mac with: a tab saved under one is this Mac's. Read once,
    /// on the calling thread, the first time a tab names an id that is not ``machine``'s (the same accepted
    /// one-time read as ``CloudDeviceID/loadNow()``).
    ///
    /// - Returns: every `device-id` of a folder under the build's Cloud folder.
    public func backendIDs() -> Set<String> {
        if let others { return others }
        let ids = Set(machinePaths.backendDeviceIDs())
        others = ids
        return ids
    }
}
