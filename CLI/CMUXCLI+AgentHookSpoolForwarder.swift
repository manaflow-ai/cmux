import Darwin
import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    /// Admits events a session's hooks published to its spool before a direct
    /// hook takes its own queue position.
    ///
    /// Direct CLI hooks (a decision barrier, or a producer's fallback) call this
    /// so an event published earlier is never ordered after a later one. It also
    /// waits for a forwarder's final drain of a retired spool. It is a no-op
    /// outside a spooled session.
    func admitSpooledAgentHooks(
        agent: String,
        client: SocketClient,
        socketPassword: String?,
        processEnvironment: [String: String]
    ) {
        guard !client.isRelayBacked,
              processEnvironment["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] != "1",
              let path = processEnvironment[
                  AgentHookSpoolProducer(agent: agent).spoolDirectoryEnvironmentKey
              ],
              path.hasPrefix("/") else {
            return
        }
        let live = AgentHookSpoolDirectory(url: URL(fileURLWithPath: path))
        for spool in [live, live.retiredLocation] where spool.isPrivate() {
            // The forwarder holds this lock only while admitting a bounded
            // batch, each admission limited by the queue's short timeout.
            guard let drainLock = spool.lock(AgentHookSpoolDirectory.drainLockName, blocking: true) else {
                continue
            }
            withExtendedLifetime(drainLock) {
                _ = admitPublishedAgentHookRecords(in: spool) { record in
                    // Everything in a retired spool was published before the
                    // agent exited, and is drained after it.
                    try admitAgentHookSpoolRecord(
                        record,
                        agentExited: spool.url == live.retiredLocation.url,
                        client: client,
                        socketPassword: socketPassword
                    )
                }
            }
        }
    }

    /// Runs one agent session's hook forwarder until the agent exits.
    ///
    /// The agent wrapper starts this in the background just before it execs the
    /// agent, so the agent is this process's parent. Queued hook events arrive
    /// as spool records instead of CLI launches; one socket connection admits
    /// them in publication order. When the socket connection fails, the
    /// forwarder exits so every later hook falls back to the CLI, which also
    /// drains any record left behind.
    func runAgentHookSpoolForwarder(
        agent: String,
        socketPath: String,
        socketPassword: String?
    ) async {
        let environment = ProcessInfo.processInfo.environment
        let producer = AgentHookSpoolProducer(agent: agent)
        let pidKey = Self.agentHookPIDEnvironmentVariable(agentName: agent)
        guard let path = environment[producer.spoolDirectoryEnvironmentKey], path.hasPrefix("/") else {
            return
        }
        let spool = AgentHookSpoolDirectory(url: URL(fileURLWithPath: path))
        let client = SocketClient(path: socketPath)
        guard let parentPID = environment[pidKey].flatMap(Int32.init), parentPID > 1,
              parentPID == getppid(), !client.isRelayBacked,
              spool.createLockFiles() else {
            // Nothing was published yet; an empty directory is removable, and
            // producers without a key list use the CLI.
            spool.removeAll()
            return
        }
        guard let lifetimeLock = spool.lock(AgentHookSpoolDirectory.forwarderLockName, blocking: false) else {
            return
        }
        guard spool.publishEnvironmentKeys(Self.agentHookSpoolEnvironmentKeys(agent: agent)) else {
            withExtendedLifetime(lifetimeLock) {
                spool.removeIfUninitialized()
            }
            return
        }

        var connected = true
        let watcher = AgentHookSpoolWatcher(directory: spool.url)
        for await _ in await watcher.changes(parentPID: parentPID) {
            connected = forwardPublishedAgentHookRecords(
                in: spool, agentExited: false, client: client, socketPassword: socketPassword
            )
            if !connected { break }
        }
        guard connected else {
            // Unclaimed records stay for the next CLI hook's drain. Releasing
            // the lifetime lock sends every later producer to the CLI.
            client.close()
            withExtendedLifetime(lifetimeLock) {}
            return
        }
        // Move the spool aside so no producer can publish after the final
        // drain; a producer that loses the rename takes the CLI path and its
        // drain waits for this one on the retired spool's drain lock.
        let finalSpool = spool.retire() ?? spool
        if forwardPublishedAgentHookRecords(
            in: finalSpool, agentExited: true, client: client, socketPassword: socketPassword
        ) {
            finalSpool.removeAll()
        }
        client.close()
        withExtendedLifetime(lifetimeLock) {}
    }

    /// The hook environment values admission reads, in producer order.
    static func agentHookSpoolEnvironmentKeys(agent: String) -> [String] {
        var seen = Set<String>()
        return (queuedAgentHookDataEnvironmentKeys(agent: agent)
            + AgentLaunchEnvironmentPolicy().inputEnvironmentKeys)
            .filter { seen.insert($0).inserted }
    }

    /// Admits the spool's published records over the forwarder's connection.
    ///
    /// A connection the app closed (for example across an app restart) is
    /// detected before sending and replaced. A failed send is not retried: the
    /// app may already have admitted the event, and a retry could duplicate it.
    ///
    /// - Returns: `false` when the socket connection failed; unclaimed records
    ///   then stay in the spool.
    private func forwardPublishedAgentHookRecords(
        in spool: AgentHookSpoolDirectory,
        agentExited: Bool,
        client: SocketClient,
        socketPassword: String?
    ) -> Bool {
        guard let drainLock = spool.lock(AgentHookSpoolDirectory.drainLockName, blocking: true) else {
            // The spool was retired or removed; nothing remains to admit.
            return true
        }
        return withExtendedLifetime(drainLock) {
            admitPublishedAgentHookRecords(in: spool, beforeClaim: {
                if client.socketFD >= 0, !client.connectionAppearsOpen() {
                    client.close()
                }
                try connectAgentHookForwarder(client, socketPassword: socketPassword)
            }) { record in
                try admitAgentHookSpoolRecord(
                    record, agentExited: agentExited, client: client, socketPassword: socketPassword
                )
            }
        }
    }

    private func connectAgentHookForwarder(_ client: SocketClient, socketPassword: String?) throws {
        guard client.socketFD < 0 else { return }
        let timeout = Self.agentHookAdmissionResponseTimeoutSeconds
        try client.connectWithoutRetry(responseTimeout: timeout)
        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPassword,
            socketPath: client.socketPath,
            responseTimeout: timeout
        )
    }

    /// Claims and admits records in publication order.
    ///
    /// Callers hold the spool's drain lock. A record the app rejects (for
    /// example `queue_full` for replaceable tool telemetry) is dropped, exactly
    /// as its CLI admission would have been, and draining continues so later
    /// records keep their order. A transport failure stops the drain and leaves
    /// the remaining records unclaimed for the next drainer.
    ///
    /// - Returns: `false` when a transport failure stopped the drain.
    private func admitPublishedAgentHookRecords(
        in spool: AgentHookSpoolDirectory,
        beforeClaim: () throws -> Void = {},
        admit: (AgentHookSpoolRecord) throws -> Void
    ) -> Bool {
        for name in spool.publishedRecordNames() {
            // Connection/authentication has not submitted this event. Preserve
            // it on failure so a later drainer can still admit it safely.
            do {
                try beforeClaim()
            } catch {
                return false
            }
            guard let record = spool.claim(name: name) else { continue }
            do {
                try admit(record)
            } catch let error as CLIError where error.isStructuredProtocolResponse {
                continue
            } catch {
                return false
            }
        }
        return true
    }

    private func admitAgentHookSpoolRecord(
        _ record: AgentHookSpoolRecord,
        agentExited: Bool,
        client: SocketClient,
        socketPassword: String?
    ) throws {
        // The producer only writes queued events; anything else is not ours.
        guard Self.agentHookCanRunQueued(agent: record.agent, subcommand: record.subcommand) else {
            return
        }
        var environment = record.environment
        if agentExited,
           let surfaceID = environment["CMUX_SURFACE_ID"],
           UUID(uuidString: surfaceID) != nil {
            // The agent PID no longer identifies its terminal. Deliver by the
            // surface instead, which the app re-homes if the pane moved.
            environment[Self.agentHookRouteSnapshotEnvironmentKey] = "1"
        }
        try admitQueuedAgentHook(
            agent: record.agent,
            subcommand: record.subcommand,
            rawPayload: String(data: record.payload, encoding: .utf8) ?? "{}",
            processEnvironment: environment,
            client: client,
            socketPassword: socketPassword,
            resolvesProcessRoute: !agentExited
        )
    }
}
