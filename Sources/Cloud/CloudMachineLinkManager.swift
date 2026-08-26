import Foundation

/// The app's headless cmux-tui links, one per awake cloud machine. Links are created on
/// demand (a tree read, a terminal open) — never to list a sleeping machine, since the
/// control plane wakes a machine on attach — and torn down when the machine is deleted
/// or the account signs out.
///
/// Enrollment mirrors the pane path: the control plane mints the route (and, for a
/// device this machine has not seen, an invitation); the link claims it while the
/// manager approves the pending enrollment through the control plane and stores the
/// device fingerprint beside the CLI's (`vm-tui-devices.json`).
actor CloudMachineLinkManager {
    struct LinkStatus: Sendable, Equatable {
        let state: CloudTreeLinkState
        let error: String?
    }

    enum ManagerError: Error, LocalizedError {
        case clientMissing
        case retryLater(String)

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return "No cmux-tui client is bundled with this build (Contents/Resources/bin/cmux-tui) and CMUX_TUI_CLIENT is unset."
            case .retryLater(let detail):
                return detail
            }
        }
    }

    private let paths: CloudTuiClientPaths
    private let clientURL: URL?
    private var links: [String: CloudMachineLink] = [:]
    private var connecting: [String: Task<CloudMachineLink.Connected, Error>] = [:]
    private var lastFailure: [String: (at: Date, error: String)] = [:]
    /// A failed link is not retried for this long, so a polling sidebar does not hammer
    /// a machine whose route is broken.
    private let retryBackoff: TimeInterval = 15

    init(
        paths: CloudTuiClientPaths = CloudTuiClientPaths(),
        clientURL: URL? = CloudTuiClientPaths.clientURL()
    ) {
        self.paths = paths
        self.clientURL = clientURL
    }

    var hasClient: Bool { clientURL != nil }

    /// The link for `machineID`, connecting (and enrolling) if needed.
    func connected(machineID: String) async throws -> CloudMachineLink.Connected {
        if let link = links[machineID], await link.isConnected, let connected = await link.connected {
            return connected
        }
        if let inFlight = connecting[machineID] {
            return try await inFlight.value
        }
        if let failure = lastFailure[machineID], Date().timeIntervalSince(failure.at) < retryBackoff {
            throw ManagerError.retryLater(failure.error)
        }
        guard let clientURL else { throw ManagerError.clientMissing }
        let task = Task<CloudMachineLink.Connected, Error> { [paths] in
            let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
            self.store(link: link, for: machineID)
            let client = await MainActor.run { VMClient.shared }
            guard let client else {
                throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
            }
            let endpoint = try await client.openCmuxRemote(
                id: machineID,
                deviceFingerprint: paths.deviceFingerprint(for: machineID),
                clientCapabilities: Self.clientCapabilities(clientURL: clientURL)
            )
            var approval: Task<Void, Never>?
            if let invitation = endpoint.invitation {
                approval = Task { await self.approveEnrollment(machineID: machineID, invitationID: invitation.invitationId, client: client) }
            }
            defer { approval?.cancel() }
            do {
                return try await link.connect(route: endpoint.route, session: endpoint.session, invitationURI: endpoint.invitation?.uri)
            } catch {
                await link.disconnect()
                throw error
            }
        }
        connecting[machineID] = task
        defer { connecting[machineID] = nil }
        do {
            let connected = try await task.value
            lastFailure[machineID] = nil
            return connected
        } catch {
            lastFailure[machineID] = (Date(), error.localizedDescription)
            links[machineID] = nil
            throw error
        }
    }

    func link(machineID: String) -> CloudMachineLink? {
        links[machineID]
    }

    func status(machineID: String) async -> LinkStatus? {
        if let link = links[machineID] {
            return LinkStatus(state: await link.state, error: await link.lastError)
        }
        if connecting[machineID] != nil {
            return LinkStatus(state: .connecting, error: nil)
        }
        if let failure = lastFailure[machineID], Date().timeIntervalSince(failure.at) < retryBackoff {
            return LinkStatus(state: .error, error: failure.error)
        }
        return nil
    }

    func disconnect(machineID: String) async {
        connecting[machineID]?.cancel()
        connecting[machineID] = nil
        if let link = links.removeValue(forKey: machineID) {
            await link.disconnect()
        }
        lastFailure[machineID] = nil
    }

    func disconnectAll() async {
        for id in Array(links.keys) {
            await disconnect(machineID: id)
        }
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        lastFailure.removeAll()
    }

    /// Drops links for machines that no longer exist.
    func retain(machineIDs: Set<String>) async {
        for id in links.keys where !machineIDs.contains(id) {
            await disconnect(machineID: id)
        }
    }

    // MARK: - internals

    private func store(link: CloudMachineLink, for machineID: String) {
        links[machineID] = link
    }

    /// Same loop as the CLI's `vm-tui-approve`: the control plane minted the invitation
    /// for the signed-in user, so approving the claim encodes "already authenticated".
    private func approveEnrollment(machineID: String, invitationID: String, client: VMClient) async {
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let approval = try? await client.approveCmuxRemoteEnrollment(id: machineID, invitationId: invitationID) else {
                continue
            }
            if approval.state == "approved" {
                if let fingerprint = approval.deviceFingerprint, !fingerprint.isEmpty {
                    paths.saveDeviceFingerprint(fingerprint, for: machineID)
                }
                return
            }
        }
    }

    /// `remote-probe --json` → `capabilities`; the control plane picks the machine host by
    /// them (a client that sends a User-Agent earns the branded host).
    nonisolated static func clientCapabilities(clientURL: URL) -> [String] {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = ["remote-probe", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["app"] as? String) == "cmux-tui",
              let raw = object["capabilities"] as? [Any] else {
            return []
        }
        return raw.compactMap { $0 as? String }
    }
}
