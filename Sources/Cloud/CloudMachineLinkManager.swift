import CmuxFoundation
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
        let state: SurfaceLinkState
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
    private var themeTasks: [String: Task<Void, Never>] = [:]
    private var lastFailure: [String: (at: Date, error: String)] = [:]
    /// A failed link is not retried for this long, so a polling sidebar does not hammer
    /// a machine whose route is broken.
    private let retryBackoff: TimeInterval = 15
    /// This Mac's resolved Ghostty default colors ("#rrggbb"), pushed to each machine as
    /// its cmux-tui session defaults (`set-default-colors`) so remote panes render with
    /// the local theme. Injected so tests need no Ghostty runtime.
    private let hostThemeColors: @Sendable () async -> (foreground: String, background: String)?

    init(
        paths: CloudTuiClientPaths = CloudTuiClientPaths(),
        clientURL: URL? = CloudTuiClientPaths.clientURL(),
        hostThemeColors: @escaping @Sendable () async -> (foreground: String, background: String)? = {
            await MainActor.run {
                let app = GhosttyApp.shared
                return (app.defaultForegroundColor.hexString(), app.defaultBackgroundColor.hexString())
            }
        }
    ) {
        self.paths = paths
        self.clientURL = clientURL
        self.hostThemeColors = hostThemeColors
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
        #if DEBUG
        cmuxDebugLog("cloud.link.connect machine=\(machineID)")
        #endif
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
                clientCapabilities: await Self.clientCapabilities(clientURL: clientURL)
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
            #if DEBUG
            cmuxDebugLog("cloud.link.connected machine=\(machineID) socket=\(connected.socketPath)")
            #endif
            pushHostTheme(machineID: machineID, connected: connected)
            return connected
        } catch {
            let text = CloudMachineLink.errorText(error)
            lastFailure[machineID] = (Date(), text)
            links[machineID] = nil
            #if DEBUG
            cmuxDebugLog("cloud.link.failed machine=\(machineID) text=\(text)")
            #endif
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
        themeTasks[machineID]?.cancel()
        themeTasks[machineID] = nil
        if let link = links.removeValue(forKey: machineID) {
            await link.disconnect()
        }
        lastFailure[machineID] = nil
    }

    func disconnectAll() async {
        for id in Array(links.keys) {
            await disconnect(machineID: id)
        }
        for task in themeTasks.values { task.cancel() }
        themeTasks.removeAll()
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

    /// Re-sends this Mac's theme to every connected machine (a Ghostty config reload
    /// changed the resolved colors). Live attach panes repaint via `colors-changed`.
    func pushHostThemeToConnectedLinks() async {
        for (machineID, link) in links {
            guard await link.isConnected, let connected = await link.connected else { continue }
            pushHostTheme(machineID: machineID, connected: connected)
        }
    }

    // MARK: - internals

    /// Fire-and-forget: theme parity is cosmetic, so a machine that predates
    /// `set-default-colors` (or a link that just dropped) must not fail the operation
    /// that connected it.
    private func pushHostTheme(machineID: String, connected: CloudMachineLink.Connected) {
        themeTasks[machineID]?.cancel()
        guard let link = links[machineID] else { return }
        let task = Task { [hostThemeColors] in
            guard !Task.isCancelled,
                  await link.isConnected,
                  await link.connected == connected,
                  let colors = await hostThemeColors(),
                  let arguments = CloudTuiCommandLine.setDefaultColorsArguments(
                      socketPath: connected.socketPath,
                      foreground: colors.foreground,
                      background: colors.background
                  ) else { return }
            do {
                _ = try await link.run(arguments: arguments)
                guard !Task.isCancelled,
                      await link.isConnected,
                      await link.connected == connected else { return }
                #if DEBUG
                cmuxDebugLog("cloud.link.theme machine=\(machineID) fg=\(colors.foreground) bg=\(colors.background)")
                #endif
            } catch {
                #if DEBUG
                cmuxDebugLog("cloud.link.themeFailed machine=\(machineID) error=\(CloudMachineLink.errorText(error))")
                #endif
            }
        }
        themeTasks[machineID] = task
    }

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
    nonisolated static func clientCapabilities(clientURL: URL) async -> [String] {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = ["remote-probe", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let stopper = CloudLinkProcessStopper(process: process, handles: [out.fileHandleForReading])
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { finished in exit.resolve(finished.terminationStatus) }
        let reader = BoundedReadState(maximumBytes: CloudLinkPipe.maximumDiagnosticOutputBytes)
        reader.install(on: out.fileHandleForReading)
        let output = Task {
            await reader.result()
        }
        do {
            try process.run()
        } catch {
            exit.resolve(nil)
            stopper.stop()
            reader.cancel()
            _ = await output.value
            return []
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                stopper.stop()
                reader.cancel()
                return true
            } catch {
                return false
            }
        }
        let status = await withTaskCancellationHandler {
            await exit.result ?? process.terminationStatus
        } onCancel: {
            stopper.stop()
            reader.cancel()
            exit.resolve(nil)
        }
        deadline.cancel()
        let timedOut = await deadline.value
        let result = await output.value
        stopper.stop()
        process.terminationHandler = nil
        guard !Task.isCancelled, !timedOut, !result.truncated, status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              (object["app"] as? String) == "cmux-tui",
              let raw = object["capabilities"] as? [Any] else {
            return []
        }
        return raw.compactMap { $0 as? String }
    }
}
