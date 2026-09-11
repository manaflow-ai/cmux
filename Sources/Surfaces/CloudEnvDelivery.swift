import Foundation

/// How environment variables reach a machine without ever being a secret in transit.
///
/// `cmux vm env set` used to be tempting to build on `vm.exec`, the way `vm push` is —
/// but that channel is Mac → cmux control plane → provider API → guest, so every value
/// would sit in plaintext on two servers and in a shell command line. This path uses
/// the one channel that is end to end: the machine's cmux-tui link (Noise-authenticated
/// between this Mac and the daemon, riding the private WireGuard network, brokered but
/// never read by the control plane).
///
/// The protocol, shared with the in-VM shim's `cmux env receive` (web/services/vms/
/// guestCli.ts) and with a machine delivering to a linked peer:
///
/// 1. Start `cmux env receive` as a terminal in the machine's session. It turns PTY echo
///    off, THEN prints `CMUX-ENV-READY`. Nothing is typed before that line is seen, so
///    no byte of a value is ever echoed into scrollback (the daemon does not journal
///    terminal input at all; it only keeps output).
/// 2. Type the payload: 76-column base64 lines of `KEY=VALUE\n` records, then a
///    `CMUX-ENV-END` line. Values are byte-literal; the receiver does no dotenv parsing.
/// 3. The receiver writes `~/.config/cmux/env` (mode 0600) and prints
///    `CMUX-ENV-OK keys=<n> path=<file>` or `CMUX-ENV-ERR <reason>`; the sender waits
///    for that line, then closes the terminal so no exit receipt lingers.
///
/// What is left exposed is only what the machine itself must hold: a root-only file on
/// its persistent volume, which forks and snapshots of that machine inherit.
enum CloudEnvDelivery {
    /// Absolute: the daemon's own PATH is not a login shell's.
    static let receiverCommand = ["/usr/local/bin/cmux", "env", "receive"]
    static let receiverTitle = "cmux env"
    static let readyMarker = "CMUX-ENV-READY"
    static let endMarker = "CMUX-ENV-END"
    static let resultPattern = "CMUX-ENV-(OK|ERR)"
    /// The receiver is a shell script that starts in well under a second; a machine that
    /// is waking or whose shim predates the verb shows neither marker in this time.
    static let readyTimeoutMs = 15_000
    static let resultTimeoutMs = 30_000
    /// One `terminal write` per chunk: small enough that the receiver's line reads keep
    /// pace with the PTY's input buffer, large enough that an ordinary `.env` is 1–2 writes.
    static let chunkBytes = 1_024
    static let maxPayloadBytes = 256 * 1_024
    static let base64LineWidth = 76

    struct Entry: Equatable, Sendable {
        let key: String
        let value: String
    }

    enum Outcome: Equatable, Sendable {
        case ok(keys: Int, path: String?)
        case failed(String)
    }

    @MainActor
    static func withReceiverWorkspace(
        createWorkspace: @MainActor () async throws -> String,
        closeWorkspace: @escaping @MainActor (String) async throws -> Void,
        operation: @MainActor (String) async throws -> Outcome
    ) async throws -> Outcome {
        let workspaceID = try await createWorkspace()
        let outcome: Outcome
        do {
            outcome = try await operation(workspaceID)
        } catch let operationError {
            do {
                try await closeReceiverWorkspace(workspaceID, closeWorkspace: closeWorkspace)
            } catch let cleanupError as DeliveryError {
                throw OperationAndCleanupError(operationError: operationError, cleanupError: cleanupError)
            }
            throw operationError
        }
        try await closeReceiverWorkspace(workspaceID, closeWorkspace: closeWorkspace)
        return outcome
    }

    @MainActor
    static func removeReceiverResources(
        terminalIDs: [String],
        discoverTerminalIDs: @MainActor () async throws -> [String] = { [] },
        closeTerminal: @MainActor (String) async throws -> Void,
        closeWorkspace: @MainActor () async throws -> Void
    ) async throws {
        let receiverTerminalIDs = terminalIDs.isEmpty ? try await discoverTerminalIDs() : terminalIDs
        for terminalID in receiverTerminalIDs { try await closeTerminal(terminalID) }
        try await closeWorkspace()
    }

    @MainActor
    private static func closeReceiverWorkspace(
        _ workspaceID: String,
        closeWorkspace: @escaping @MainActor (String) async throws -> Void
    ) async throws {
        do {
            try await Task { @MainActor in try await closeWorkspace(workspaceID) }.value
        } catch {
            throw DeliveryError.workspaceCleanupFailed(workspaceID)
        }
    }

    struct OperationAndCleanupError: Error, LocalizedError {
        let operationError: any Error
        let cleanupError: DeliveryError

        var errorDescription: String? {
            let primaryDescription: String
            if let deliveryError = operationError as? DeliveryError {
                primaryDescription = deliveryError.localizedDescription
            } else if operationError is CancellationError {
                primaryDescription = String(localized: "cloudEnv.error.deliveryCancelled", defaultValue: "Environment delivery was cancelled.")
            } else {
                primaryDescription = String(localized: "cloudEnv.error.deliveryFailed", defaultValue: "Environment delivery failed.")
            }
            return "\(primaryDescription) \(cleanupError.localizedDescription)"
        }
    }

    enum DeliveryError: Error, LocalizedError, Equatable {
        case invalidKey(String)
        case multilineValue(String)
        case emptyPayload
        case tooLarge(Int)
        case receiverNotReady(String)
        case outdatedShim(String)
        case receiverFailed(String)
        case noResult(String)
        case workspaceCleanupFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let key):
                return "invalid variable name '\(key)' (keys match [A-Za-z_][A-Za-z0-9_]*)"
            case .multilineValue(let key):
                return "value of \(key) must be a single line"
            case .emptyPayload:
                return "no variables to set"
            case .tooLarge(let bytes):
                return "environment payload is \(bytes) bytes; the limit is \(maxPayloadBytes)"
            case .receiverNotReady(let screen):
                return "the machine's `cmux env receive` did not report ready\(Self.detail(screen))"
            case .outdatedShim(let machine):
                return "\(machine)'s cmux shim predates `cmux env` — reconnect it (cmux vm tree \(machine) --refresh) to heal, then retry"
            case .receiverFailed(let reason):
                return "the machine refused the environment: \(reason)"
            case .noResult(let screen):
                return "the machine's `cmux env receive` ended without a result\(Self.detail(screen))"
            case .workspaceCleanupFailed(let workspaceID):
                return String(format: String(localized: "cloudEnv.error.workspaceCleanupFailed", defaultValue: "The temporary environment receiver workspace %@ could not be removed. Inspect the machine before retrying."), workspaceID)
            }
        }

        private static func detail(_ screen: String) -> String {
            let trimmed = screen.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : " (screen: \(trimmed.suffix(200)))"
        }
    }

    static func requireReady(_ response: [String: Any], machineID: String) throws {
        let value = (response["value"] as? [String: Any]) ?? response
        guard (value["matched"] as? Bool) == true else {
            let screen = (value["text"] as? String) ?? ""
            if looksLikeOutdatedShim(screen) {
                throw DeliveryError.outdatedShim(machineID)
            }
            throw DeliveryError.receiverNotReady(screen)
        }
    }

    static func requireOutcome(_ response: [String: Any]) throws -> Outcome {
        let value = (response["value"] as? [String: Any]) ?? response
        let screen = (value["text"] as? String) ?? ""
        guard let outcome = outcome(fromScreen: screen) else {
            throw DeliveryError.noResult(screen)
        }
        if case .failed(let reason) = outcome {
            throw DeliveryError.receiverFailed(reason)
        }
        return outcome
    }

    static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// The receiver's payload: one `KEY=VALUE` line per entry, values byte-literal.
    static func payload(_ entries: [Entry]) throws -> Data {
        guard !entries.isEmpty else { throw DeliveryError.emptyPayload }
        var text = ""
        for entry in entries {
            guard isValidKey(entry.key) else { throw DeliveryError.invalidKey(entry.key) }
            guard !entry.value.contains("\n"), !entry.value.contains("\r") else {
                throw DeliveryError.multilineValue(entry.key)
            }
            text += "\(entry.key)=\(entry.value)\n"
        }
        let data = Data(text.utf8)
        guard data.count <= maxPayloadBytes else { throw DeliveryError.tooLarge(data.count) }
        return data
    }

    /// What gets typed into the receiver's PTY: base64 of the payload, wrapped to
    /// 76 columns (a canonical-mode line is capped at 4095 bytes; keep far below it),
    /// then the end marker on its own line.
    static func wire(_ payload: Data) -> Data {
        let encoded = payload.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: base64LineWidth, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<next]))
            index = next
        }
        lines.append(endMarker)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// `wire` split for one `terminal write` per piece. Cut points fall anywhere: the
    /// receiver reassembles lines from the byte stream, not from write boundaries.
    static func chunks(_ wire: Data, size: Int = chunkBytes) -> [Data] {
        guard size > 0, !wire.isEmpty else { return wire.isEmpty ? [] : [wire] }
        var pieces: [Data] = []
        var offset = 0
        while offset < wire.count {
            let end = min(offset + size, wire.count)
            pieces.append(wire.subdata(in: offset..<end))
            offset = end
        }
        return pieces
    }

    /// The receiver's verdict, from the screen text after `CMUX-ENV-(OK|ERR)` matched.
    /// The LAST such line wins: a retried receiver's earlier lines may still be visible.
    static func outcome(fromScreen text: String) -> Outcome? {
        var result: Outcome?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "CMUX-ENV-OK") {
                let rest = line[range.upperBound...].split(separator: " ").map(String.init)
                var keys = 0
                var path: String?
                for field in rest {
                    if field.hasPrefix("keys="), let count = Int(field.dropFirst("keys=".count)) { keys = count }
                    if field.hasPrefix("path=") { path = String(field.dropFirst("path=".count)) }
                }
                result = .ok(keys: keys, path: path)
            } else if let range = line.range(of: "CMUX-ENV-ERR") {
                let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                result = .failed(reason.isEmpty ? "unknown error" : reason)
            }
        }
        return result
    }

    /// A shim without the verb falls through to cmux-tui, which answers with an unknown
    /// resource scope; the shim's own dispatcher says "unknown env command".
    static func looksLikeOutdatedShim(_ screen: String) -> Bool {
        screen.contains("unknown resource scope") || screen.contains("unknown env command")
    }
}
