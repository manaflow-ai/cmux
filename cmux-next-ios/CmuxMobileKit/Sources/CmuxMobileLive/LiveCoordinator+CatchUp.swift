#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "catch-up")

/// One-request foreground catch-up over the Mac's `catch-up` link service (cmux#54108): the
/// phone opens that one channel with every cursor it holds and reads one reply, instead of a
/// separate call per surface. Rust (`PhoneCatchUp`) builds the request and reads the reply;
/// Swift opens the channel and hands the bytes over. Leo, 2026-11-24: "the syncing can
/// arguably happen in the background too, so deltas can be sipped and maintained".
///
/// Off by default (`enabledKey`). The terminal's `daemon` channel resumes beside it as
/// before; a Mac without the service gets today's list.
@MainActor
final class MacCatchUps {
    /// Off by default; on, a foreground asks each served Mac by one `catch-up` request.
    nonisolated static let enabledKey = "cmuxMobile.settings.catchUpOneRequest"
    /// The reply carries a whole tree at most (1.7 MB at 1,000 workspaces) and the chats'
    /// budget (at most 256 KiB): past this it is not read.
    nonisolated static let replyLimit = 8 * 1024 * 1024
    nonisolated static let replyTimeout: Duration = .seconds(20)

    nonisolated static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    private let defaults: UserDefaults
    private var cursors: [String: PhoneCatchUp] = [:]
    /// Macs that closed a `catch-up` open with `unknown_service`: asked as today until relaunch.
    private var withoutService: Set<String> = []
    private var running: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func cursorKey(_ macID: String) -> String { "cmuxMobile.catchUp.cursors.\(macID)" }

    /// The Mac's kept cursors (read once, then held).
    func cursors(for macID: String) -> PhoneCatchUp {
        if let held = cursors[macID] { return held }
        let opened = PhoneCatchUp.open(kept: defaults.data(forKey: Self.cursorKey(macID)))
        cursors[macID] = opened
        return opened
    }

    func keep(_ macID: String) {
        guard let held = cursors[macID] else { return }
        defaults.set(held.encode(), forKey: Self.cursorKey(macID))
    }

    func lacksService(_ macID: String) -> Bool { withoutService.contains(macID) }
    func markWithoutService(_ macID: String) { withoutService.insert(macID) }

    /// Runs `work` for the Mac unless one already runs.
    func run(_ macID: String, _ work: @escaping @MainActor () async -> Void) {
        guard running[macID] == nil else { return }
        running[macID] = Task { [weak self] in
            await work()
            self?.running[macID] = nil
        }
    }

    /// Reads the one reply frame (the channel closes after it).
    nonisolated static func readReply(_ channel: any LinkChannel) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var bytes = Data()
                    while let chunk = try await channel.receive() {
                        bytes.append(chunk)
                        guard bytes.count <= replyLimit else {
                            throw LinkError(code: "too_large", message: "catch-up reply past \(replyLimit) bytes")
                        }
                    }
                    if bytes.isEmpty, let error = channel.closedBy, error.code != "eof" { throw error }
                    return bytes
                }
                group.addTask {
                    try await Task.sleep(for: replyTimeout)
                    await channel.close(code: "timeout", reason: "catch-up timed out")
                    throw LinkError(code: "timeout", message: "catch-up timed out")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? Data()
            }
        } onCancel: {
            Task { await channel.close(code: "cancelled", reason: "catch-up cancelled") }
        }
    }
}

extension LiveCoordinator {
    /// Foreground: each served Mac catches up by one `catch-up` request (when the setting is
    /// on). The link's resume and its `daemon` channel run beside it, not after it.
    func catchUpOnForeground() {
        guard MacCatchUps.enabled() else { return }
        for session in sessions.values where session.servedLink != nil {
            let macID = session.macID
            catchUps.run(macID) { [weak self, weak session] in
                guard let self, let session else { return }
                await self.catchUp(session)
            }
        }
    }

    /// One `catch-up` round for `session`: the tree it answers is applied as a list would
    /// be; a Mac without the service, a cut tree or one the phone cannot merge lists as today.
    func catchUp(_ session: MacSession) async {
        let macID = session.macID
        if catchUps.lacksService(macID) {
            await session.workspaces.refresh()
            return
        }
        // A line still setting up lists on its own; nothing to catch up yet.
        guard let start = await session.workspaces.catchUpStart() else { return }
        let phone = catchUps.cursors(for: macID)
        let knownJSON = start.known.flatMap { known in
            (try? JSONSerialization.data(withJSONObject: known.params)).map { String(decoding: $0, as: UTF8.self) }
        }
        let args = phone.foregroundRequest(ask: CatchUpAsk(
            onScreenChat: nil,
            knownJson: knownJSON,
            capabilities: WorkspaceSync.clientCapabilities,
            chats: session.acpmux.catchUpChats().map {
                CatchUpChatAsk(sessionId: $0.sessionID, lastSeq: UInt64(clamping: max(0, $0.lastSeq)))
            },
            budgetBytes: 0))
        let reply: Data
        do {
            let link = try await pairedLink(session)
            let channel = try await link.openChannel(service: catchUpService(), argsJSON: args)
            reply = try await MacCatchUps.readReply(channel)
            if reply.isEmpty, let closed = channel.closedBy, catchUpFallsBack(code: closed.code) {
                throw closed
            }
        } catch let error as LinkError where catchUpFallsBack(code: error.code) {
            log.info("catch-up: \(macID, privacy: .public) has no catch-up service; listing as today")
            catchUps.markWithoutService(macID)
            await session.workspaces.refresh()
            return
        } catch {
            log.error("catch-up: \(macID, privacy: .public) \(String(describing: error), privacy: .public)")
            return
        }
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        let answer: CatchUpAnswer
        do {
            answer = try phone.apply(reply: reply, now: now)
        } catch {
            log.error("catch-up reply: \(String(describing: error), privacy: .public)")
            await session.workspaces.refresh()
            return
        }
        catchUps.keep(macID)
        for cut in answer.cut {
            log.info("catch-up: \(macID, privacy: .public) cut \(cut.name, privacy: .public): \(cut.reason, privacy: .public)")
        }
        // The chat list and chat pages moved the kept cursors only: the hub's own watch and
        // attach still bring the chats up on this link.
        switch answer.tree {
        case .whole?, .unchanged?:
            let data = Data((answer.workspacesJson ?? "{}").utf8)
            let applied = await session.workspaces.applyCatchUp(
                data, unchanged: answer.tree == .unchanged, coveredThrough: start.coveredThrough)
            if !applied { await session.workspaces.refresh() }
        case .delta?, nil:
            await session.workspaces.refresh()
        }
    }
}
#endif
