import Foundation

/// The grants to end of chats brought back from a Cloud machine (``CloudAccessAsks``): each runs
/// `cmux link access revoke --all` until it answers ok. It waits for its machine's link, so the
/// revoke also deletes the read-only copies there (`--socket`); a machine this app no longer has
/// ends only this Mac's record. A failure never fails a bring back; it is logged and tried again.
@MainActor
final class CloudAccessRevokes {
    struct Chat: Hashable {
        var machineID: String
        var session: String
    }

    private var pending: Set<Chat> = []
    private var running: Set<Chat> = []
    /// Revoked in this run of the app: a ledger entry still marked brought back isn't revoked again.
    private var done: Set<Chat> = []

    var isEmpty: Bool { pending.isEmpty }

    func add(_ chat: Chat) {
        if !done.contains(chat) { pending.insert(chat) }
    }

    /// Runs every pending revoke whose machine is reachable, one at a time per chat.
    func run(_ cli: CloudAccessCLI, services: AppServices) async {
        let logger = services.cloud.logger
        for chat in pending.subtracting(running).sorted(by: { ($0.machineID, $0.session) < ($1.machineID, $1.session) }) {
            var socket: String?
            if let machine = services.machines.session(chat.machineID) {
                // Disconnected: wait for the link, so the copies there go too.
                guard let path = await machine.daemon.connection?.endpoint?.socketPath else { continue }
                socket = path
            }
            // Another run may have taken it meanwhile.
            guard pending.contains(chat), !running.contains(chat) else { continue }
            running.insert(chat)
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await cli.revoke(socket: socket, machine: chat.machineID, session: chat.session)
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            running.remove(chat)
            if answer.ok {
                pending.remove(chat)
                done.insert(chat)
            } else {
                logger.error("cloud access revoke: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)")
            }
        }
    }
}
