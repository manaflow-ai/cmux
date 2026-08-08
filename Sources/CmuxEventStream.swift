import CmuxControlSocket
import Darwin
import Dispatch
import Foundation

extension TerminalController {
    nonisolated func isEventsStreamRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return method == "events.stream"
    }

    nonisolated func handleEventsStreamRequest(
        _ line: String,
        socket: Int32,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal,
        passwordAuthorization: SocketPasswordAuthorization
    ) {
        var streamPasswordAuthorization = passwordAuthorization
        guard socketEventStreamAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &streamPasswordAuthorization
        ) else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard socketEventStreamAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &streamPasswordAuthorization
            ) else { return }
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_request", "message": "events.stream requires a JSON object"]
            ], socket: socket)
            return
        }

        let params = object["params"] as? [String: Any] ?? [:]
        let afterSequence = CmuxEventBus.int64(params["after_seq"] ?? params["after"])
        let names = Self.stringSet(params["names"] ?? params["name"])
        let categories = Self.stringSet(params["categories"] ?? params["category"])
        let includeHeartbeats = Self.boolParam(params["include_heartbeats"] ?? params["include_heartbeat"]) ?? true

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: afterSequence,
            names: names,
            categories: categories
        )
        let revocationSource = socketEventStreamRevocationSource(
            authorizationRevocationSignal,
            subscription: snapshot.subscription
        )
        defer {
            revocationSource?.cancel()
            CmuxEventBus.shared.unsubscribe(snapshot.subscription)
        }

        guard socketEventStreamAuthorizationIsCurrent(
                  authorizationGeneration,
                  passwordAuthorization: &streamPasswordAuthorization
              ),
              writeEventsStreamLine(snapshot.ack, socket: socket) else { return }
        for event in snapshot.replay {
            guard socketEventStreamAuthorizationIsCurrent(
                      authorizationGeneration,
                      passwordAuthorization: &streamPasswordAuthorization
                  ),
                  writeEventsStreamLine(event, socket: socket) else { return }
        }

        while socketEventStreamAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &streamPasswordAuthorization
        ) {
            let event = snapshot.subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds)
            guard socketEventStreamAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &streamPasswordAuthorization
            ) else { return }
            if let event {
                guard writeEventsStreamLine(event, socket: socket) else { return }
            } else if snapshot.subscription.isClosed {
                if let reason = snapshot.subscription.closeReason {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": [
                            "code": "slow_consumer",
                            "message": reason,
                            "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
                        ]
                    ], socket: socket)
                }
                return
            } else if includeHeartbeats,
                      socketEventStreamAuthorizationIsCurrent(
                          authorizationGeneration,
                          passwordAuthorization: &streamPasswordAuthorization
                      ) {
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: snapshot.subscription)
                guard writeEventsStreamLine(heartbeat, socket: socket) else { return }
            } else if Self.socketPeerClosed(socket) {
                return
            }
        }
    }

    private nonisolated func socketEventStreamRevocationSource(
        _ signal: SocketAuthorizationRevocationSignal,
        subscription: CmuxEventSubscription
    ) -> (any DispatchSourceRead)? {
        let signalDescriptor = signal.readFileDescriptor
        guard signalDescriptor >= 0 else { return nil }

        // Dispatch source cancellation is asynchronous. Give the source its
        // own descriptor so the signal may release its copy without racing a
        // pending event handler, then close this copy in the cancel handler.
        let descriptor = dup(signalDescriptor)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        // DispatchSource bridges the pollable revocation pipe into the
        // subscription's existing wake signal without a timer or polling loop.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            subscription.close()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.activate()
        return source
    }

    nonisolated func publishSocketEvents(
        command: String,
        response: String,
        caller: () -> CmuxSocketCallerIdentity
    ) {
        CmuxSocketEventMapper.publish(command: command, response: response, caller: caller)
    }

    /// Resolves who is on the other end of a control-socket connection, entirely
    /// from kernel state (https://github.com/manaflow-ai/cmux/issues/9611).
    ///
    /// `pid` is the accept-time `LOCAL_PEERPID`, which is a snapshot: the peer
    /// may have exited and the kernel may have recycled its pid by the time an
    /// event is published. Every derived field is therefore bound to the process
    /// generation (pid + start time) read here, and the generation is
    /// revalidated after the surface lookup. If it changed, the derived fields
    /// are dropped rather than published, so an event never attributes a
    /// recycled pid's terminal to the process that opened the connection.
    ///
    /// The surface comes from the caller process's controlling terminal matched
    /// against live Ghostty PTYs, reusing the same `.controllingTTY` resolution
    /// agent hooks use, so a caller cannot claim a surface it is not running in.
    /// Nothing here reads the request.
    ///
    /// Cost: one `proc_pidinfo` call, one bounded-cache name lookup, and, only
    /// for a caller that actually owns a controlling terminal, one main hop.
    /// Callers with no tty (daemons, GUI clients, `cmuxd`) never hop. The hop is
    /// `v2MainSync`, the same bridge every socket command already uses to read
    /// main-actor state, and it runs at most once per connection because the
    /// peer pid is fixed for a connection's lifetime. It stays synchronous
    /// because the control-socket read loop is synchronous: making publication
    /// async would reorder event emission relative to the socket response the
    /// event reports on.
    nonisolated func socketCallerIdentity(
        peerProcessID pid: pid_t?,
        resolver: CmuxSocketCallerResolver
    ) -> CmuxSocketCallerIdentity {
        guard let pid, pid > 0, let snapshot = resolver.processSnapshot(pid: pid) else {
            return CmuxSocketCallerIdentity(pid: pid, processName: nil, surfaceId: nil)
        }
        let processName = resolver.processName(for: snapshot.generation)

        // No controlling terminal means the caller cannot be inside a pane, so
        // skip the surface scan and the main hop entirely.
        var surfaceId: String?
        if snapshot.ttyDevice != nil {
            surfaceId = v2MainSync(commandKey: "socket.caller.identity") {
                AppDelegate.shared?
                    .liveAgentDeliveryTarget(forAgentPID: pid, resolution: .controllingTTY)?
                    .surfaceId
                    .uuidString
            }
        }

        // The lookups above are not atomic with the snapshot. If the pid was
        // recycled in between, both derived fields describe the wrong process.
        guard resolver.generationIsCurrent(snapshot.generation) else {
            return CmuxSocketCallerIdentity(pid: pid, processName: nil, surfaceId: nil)
        }
        return CmuxSocketCallerIdentity(pid: pid, processName: processName, surfaceId: surfaceId)
    }

    private nonisolated func writeEventsStreamLine(_ object: [String: Any], socket: Int32) -> Bool {
        autoreleasepool {
            guard let line = CmuxEventBus.encodeLine(object) else { return false }
            return transport.writeAll(Data((line + "\n").utf8), to: socket)
        }
    }

    private nonisolated static func stringSet(_ value: Any?) -> Set<String> {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let values = value as? [String] {
            return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return []
    }

    private nonisolated static func boolParam(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if number.compare(NSNumber(value: 0)) == .orderedSame { return false }
            if number.compare(NSNumber(value: 1)) == .orderedSame { return true }
            return nil
        }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    private nonisolated static func socketPeerClosed(_ socket: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result == 0 {
            return true
        }
        if result > 0 {
            return false
        }
        let errorCode = errno
        return errorCode != EAGAIN && errorCode != EWOULDBLOCK && errorCode != EINTR
    }
}
