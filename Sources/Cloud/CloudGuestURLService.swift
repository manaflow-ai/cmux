import CmuxBrowser
import CmuxCloud
import AppKit
import CmuxCloudMachines
import CmuxCloudTui
import Foundation

/// Owns one ephemeral opener subscription per connected VM. The daemon holds
/// requests only while this process is alive; rejection and disconnect unblock
/// the guest with a printable fallback. Auth URLs never enter persistent state.
@MainActor
final class CloudGuestURLService {
    private let executable: URL?
    private let machineID: String
    private let resolve: (String) -> TerminalLinkOpenRequest?
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var terminals: [String] = []
    private var socketPath: String?
    private var link: CloudMachineLink?
    private var generation = UUID()
    private var admission = CloudMachineNotificationGate()
    private var subscription = CloudGuestURLSubscriptionState()

    init(machineID: String, executable: URL?, resolve: @escaping (String) -> TerminalLinkOpenRequest?) {
        self.machineID = machineID
        self.executable = executable
        self.resolve = resolve
    }

    func update(link: CloudMachineLink, socketPath: String, terminals: [String]) {
        let sorted = Array(Set(terminals)).sorted()
        // An older client/daemon may reject this optional subscription. Retry
        // only after topology or connection changes, never on every state tick.
        if self.socketPath == socketPath, self.link === link, self.terminals == sorted { return }
        stop()
        self.link = link
        self.socketPath = socketPath
        self.terminals = sorted
        start()
    }

    private func start() {
        guard let executable, let link, let socketPath, !terminals.isEmpty, terminals.count <= 256 else { return }
        let taskGeneration = generation
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(socket: socketPath, request: ["cmd": "url-open-subscribe", "terminal_ids": terminals], stream: true)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Foundation must retain a running Process through its actual exit.
        // Break this deliberate self-retain when SIGTERM/socket EOF completes.
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { [process] ended in
            exit.resolve(ended.terminationStatus)
            process.terminationHandler = nil
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        // Reuse the existing nonblocking process pipe reader; at most 16 daemon
        // requests can be outstanding, and each must be claimed before opening.
        let lines = CloudLinkPipe.lines(from: stdout.fileHandleForReading, bufferingPolicy: .bufferingNewest(16))
        do { try process.run() } catch { process.terminationHandler = nil; return }
        self.process = process
        reader = Task { [weak self] in
            for await line in lines {
                guard !Task.isCancelled, let self, self.generation == taskGeneration else { return }
                guard let data = line.data(using: .utf8), let request = CloudGuestURLRequest(data: data) else { continue }
                await self.deliver(request, link: link, generation: taskGeneration)
            }
            guard let status = await exit.result, let self, self.generation == taskGeneration else { return }
            self.subscription.ended(exitCode: status)
        }
    }

    func recoverOnLinkProgress() {
        guard subscription.recoverOnLinkProgress() else { return }
        start()
    }

    func updateTerminals(_ terminals: [String]) {
        guard let link, let socketPath else { return }
        update(link: link, socketPath: socketPath, terminals: terminals)
    }

    func stop() {
        subscription = CloudGuestURLSubscriptionState()
        generation = UUID()
        reader?.cancel()
        reader = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        link = nil
        socketPath = nil
        terminals = []
    }

    private func deliver(_ request: CloudGuestURLRequest, link: CloudMachineLink, generation: UUID) async {
        guard let initial = resolve(request.terminalID), terminals.contains(request.terminalID),
              admission.admit(machineID: machineID, event: CloudMachineNotificationEvent(
                  id: request.requestID, terminalID: request.terminalID, title: "url-open", body: request.url
              )) == .allowed else { return }
        // A claim is rejected once the guest's bounded wait has expired.
        guard let data = try? await link.run(arguments: CloudTuiRequest(
            "url-open-claim", ["request_id": request.requestID], raw: true
        ), timeout: .seconds(4)),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["claimed"] as? Bool == true,
              self.generation == generation, !Task.isCancelled else { return }
        var opened = false
        if let current = resolve(request.terminalID), current.sourceWorkspaceId == initial.sourceWorkspaceId {
            var externalURL: URL?
            let coordinator = TerminalLinkOpenCoordinator(externalOpen: { externalURL = $0; return true }, recordsDiagnostics: false)
            var context = current
            context = TerminalLinkOpenRequest(rawValue: request.url, sourceWorkspaceId: context.sourceWorkspaceId,
                                              sourcePanelId: context.sourcePanelId, workingDirectory: nil, focus: false)
            opened = coordinator.open(context)
            if let externalURL {
                opened = await BrowserExternalAppOpener()
                    .openAwaitingCompletion(externalURL, activates: false)
            }
        }
        guard self.generation == generation, !Task.isCancelled else { return }
        _ = try? await link.run(arguments: CloudTuiRequest(
            "url-open-result", ["request_id": request.requestID, "opened": opened], raw: true
        ), timeout: .seconds(4))
    }

    private func arguments(socket: String, request: [String: Any], stream: Bool = false) -> [String] {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["--socket", socket, stream ? "--jsonl" : "--json", "raw", "command", "--request-json", json]
            + (stream ? ["--stream"] : [])
    }
}
