import Foundation

/// One file to a machine over its link — for anything that must never transit
/// `vm.exec`: a token file, a deploy key, an `.npmrc`, a kubeconfig.
///
/// `cmux vm push` moves bytes as base64 inside exec command lines, which is the
/// right tool for a source tree and the wrong one for a secret: every chunk sits
/// in plaintext on the control plane and the provider API. `cmux vm push --secret`
/// therefore takes the path `cmux vm env set` takes (see `CloudEnvDelivery`): the
/// machine's Noise-authenticated cmux-tui link, brokered but never read by the
/// control plane, into an in-VM receiver that turns terminal echo off before it
/// reads a byte.
///
/// The protocol, shared with the shim's `cmux file receive` (web/services/vms/
/// guestCli.ts) and with a machine delivering to a linked peer:
///
/// 1. Start `cmux file receive <path> [--mode <octal>]` as a terminal in the
///    machine's session. It turns PTY echo off, THEN prints `CMUX-FILE-READY`.
/// 2. Type the payload: 76-column base64 lines of the raw file bytes, then a
///    `CMUX-FILE-END` line.
/// 3. The receiver decodes into a temp file beside the destination, applies the
///    mode, renames it into place atomically, and prints
///    `CMUX-FILE-OK bytes=<n> path=<file> mode=<octal>` or `CMUX-FILE-ERR <reason>`;
///    the sender waits for that line, then closes the terminal.
///
/// Same limits as env delivery: 256 KiB, because the PTY is a control channel,
/// not a bulk one. Larger non-secret payloads belong to `cmux vm push`.
enum CloudFileDelivery {
    /// Absolute: the daemon's own PATH is not a login shell's.
    static let receiverProgram = "/usr/local/bin/cmux"
    static let receiverTitle = "cmux file"
    static let readyMarker = "CMUX-FILE-READY"
    static let endMarker = "CMUX-FILE-END"
    static let resultPattern = "CMUX-FILE-(OK|ERR)"
    static let readyTimeoutMs = CloudEnvDelivery.readyTimeoutMs
    /// Decoding 256 KiB through a shell pipeline is quick; the margin covers a
    /// machine that is paging the shim back in.
    static let resultTimeoutMs = 60_000
    static let maxPayloadBytes = 256 * 1_024
    static let defaultMode = "600"

    struct Request: Equatable, Sendable {
        let path: String
        let mode: String
        let data: Data
    }

    enum Outcome: Equatable, Sendable {
        case ok(bytes: Int, path: String?, mode: String?)
        case failed(String)
    }

    enum DeliveryError: Error, LocalizedError, Equatable {
        case emptyPath
        case invalidMode(String)
        case emptyPayload
        case tooLarge(Int)
        case receiverNotReady(String)
        case outdatedShim(String)
        case receiverFailed(String)
        case noResult(String)
        case byteCountMismatch(sent: Int, reported: Int)
        case workspaceCleanupFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "a destination path on the machine is required"
            case .invalidMode(let mode):
                return "invalid file mode '\(mode)' (three or four octal digits, e.g. 600 or 0644)"
            case .emptyPayload:
                return "the file is empty; nothing to deliver"
            case .tooLarge(let bytes):
                return "the file is \(bytes) bytes; secret delivery over the link is limited to \(maxPayloadBytes) bytes (use `cmux vm push` without --secret for large, non-secret files)"
            case .receiverNotReady(let screen):
                return "the machine's `cmux file receive` did not report ready\(Self.detail(screen))"
            case .outdatedShim(let machine):
                return "\(machine)'s cmux shim predates `cmux file receive` — reconnect it (cmux vm tree \(machine) --refresh) to heal, then retry"
            case .receiverFailed(let reason):
                return "the machine refused the file: \(reason)"
            case .noResult:
                return String(localized: "cloud.fileDelivery.noResult", defaultValue: "The machine's file receiver ended without a result.")
            case .byteCountMismatch(let sent, let reported):
                return "the machine wrote \(reported) bytes but \(sent) were sent; the file was not left in place"
            case .workspaceCleanupFailed(let workspaceID):
                return "the temporary file receiver workspace \(workspaceID) could not be removed; inspect the machine before retrying"
            }
        }

        private static func detail(_ screen: String) -> String {
            let trimmed = screen.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : " (screen: \(trimmed.suffix(200)))"
        }
    }

    /// A delivery that failed AND left its temporary workspace behind: both facts
    /// matter to the caller, so neither is dropped.
    struct OperationAndCleanupError: Error, LocalizedError {
        let operationError: any Error
        let cleanupError: DeliveryError

        var errorDescription: String? {
            let primary: String
            if let deliveryError = operationError as? DeliveryError {
                primary = deliveryError.localizedDescription
            } else if operationError is CancellationError {
                primary = "file delivery was cancelled"
            } else {
                primary = "file delivery failed"
            }
            return "\(primary); \(cleanupError.localizedDescription)"
        }
    }

    /// Runs `operation` inside a temporary receiver workspace that is always closed
    /// afterwards — on success, on failure, and on cancellation (the close runs in
    /// its own task so a cancelled caller still cleans up). A cleanup failure after a
    /// failed operation is reported alongside the original error.
    @MainActor
    static func withReceiverWorkspace<T>(
        createWorkspace: @MainActor () async throws -> String,
        closeWorkspace: @escaping @MainActor (String) async throws -> Void,
        operation: @MainActor (String) async throws -> T
    ) async throws -> T {
        let workspaceID = try await createWorkspace()
        let result: T
        do {
            result = try await operation(workspaceID)
        } catch let operationError {
            do {
                try await closeReceiverWorkspace(workspaceID, closeWorkspace: closeWorkspace)
            } catch let cleanupError as DeliveryError {
                throw OperationAndCleanupError(operationError: operationError, cleanupError: cleanupError)
            }
            throw operationError
        }
        try await closeReceiverWorkspace(workspaceID, closeWorkspace: closeWorkspace)
        return result
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

    /// Three or four octal digits: what `chmod` accepts and what the receiver echoes back.
    static func isValidMode(_ mode: String) -> Bool {
        mode.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil
    }

    /// What the daemon runs: the shim's receiver with its destination and mode as argv.
    /// The path is public information (it shows in the tree as the terminal's command);
    /// the bytes never are.
    static func receiverCommand(path: String, mode: String) -> [String] {
        [receiverProgram, "file", "receive", path, "--mode", mode]
    }

    static func validate(_ request: Request) throws {
        guard !request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeliveryError.emptyPath
        }
        guard isValidMode(request.mode) else { throw DeliveryError.invalidMode(request.mode) }
        guard !request.data.isEmpty else { throw DeliveryError.emptyPayload }
        guard request.data.count <= maxPayloadBytes else { throw DeliveryError.tooLarge(request.data.count) }
    }

    /// What gets typed into the receiver's PTY: base64 of the bytes wrapped to the
    /// env protocol's 76 columns (a canonical-mode line is capped at 4095 bytes), then
    /// the end marker on its own line. Split into `terminal write` pieces with
    /// `CloudEnvDelivery.chunks`; the receiver reassembles lines from the byte stream.
    static func wire(_ data: Data) -> Data {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: CloudEnvDelivery.base64LineWidth, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<next]))
            index = next
        }
        lines.append(endMarker)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func requireReady(_ response: [String: Any], machineID: String) throws {
        let value = (response["value"] as? [String: Any]) ?? response
        guard (value["matched"] as? Bool) == true else {
            let screen = (value["text"] as? String) ?? ""
            if CloudEnvDelivery.looksLikeOutdatedShim(screen) || screen.contains("unknown file command") {
                throw DeliveryError.outdatedShim(machineID)
            }
            throw DeliveryError.receiverNotReady(screen)
        }
    }

    static func requireOutcome(_ response: [String: Any], expectedBytes: Int) throws -> Outcome {
        let value = (response["value"] as? [String: Any]) ?? response
        let screen = (value["text"] as? String) ?? ""
        guard let outcome = outcome(fromScreen: screen) else {
            throw DeliveryError.noResult(screen)
        }
        switch outcome {
        case .failed(let reason):
            throw DeliveryError.receiverFailed(reason)
        case .ok(let bytes, _, _):
            // The receiver counts what it decoded; a short count means a truncated stream
            // (the receiver refuses to install a partial file, but say so precisely).
            guard bytes == expectedBytes else {
                throw DeliveryError.byteCountMismatch(sent: expectedBytes, reported: bytes)
            }
            return outcome
        }
    }

    /// The receiver's verdict, from the screen text after `CMUX-FILE-(OK|ERR)` matched.
    /// The LAST such line wins: a retried receiver's earlier lines may still be visible.
    static func outcome(fromScreen text: String) -> Outcome? {
        var result: Outcome?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "CMUX-FILE-OK") {
                var bytes = 0
                var path: String?
                var mode: String?
                // Only the leading field and final delimiter are metadata. A
                // filename may itself contain spaces and words such as bytes=900.
                if let field = line[range.upperBound...].split(separator: " ", maxSplits: 1).first,
                   field.hasPrefix("bytes="), let count = Int(field.dropFirst("bytes=".count)) {
                    bytes = count
                }
                if let modeStart = line.range(of: " mode=", options: .backwards) {
                    mode = String(line[modeStart.upperBound...])
                    if let pathStart = line.range(of: " path="), pathStart.upperBound <= modeStart.lowerBound {
                        path = String(line[pathStart.upperBound..<modeStart.lowerBound])
                    }
                }
                result = .ok(bytes: bytes, path: path, mode: mode)
            } else if let range = line.range(of: "CMUX-FILE-ERR") {
                let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                result = .failed(reason.isEmpty ? "unknown error" : reason)
            }
        }
        return result
    }
}
