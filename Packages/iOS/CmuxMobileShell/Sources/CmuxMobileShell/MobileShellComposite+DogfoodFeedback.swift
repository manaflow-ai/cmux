internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Privileged direct-to-agent feedback round-trip: package the supplied
    /// debug-log text, visible terminal text, an optional freeform note, and — on
    /// DEBUG builds only — the exported structured diagnostic log, then submit it to
    /// the paired Mac's `dogfood.feedback.submit` sink so the existing watcher under
    /// `~/.cache/cmux-dogfood-feedback/` catches it.
    ///
    /// This is the privileged path of the Send Feedback feature: it is offered
    /// only to `@manaflow.ai` users on an active mobile-host connection (see
    /// ``MobileFeedbackRoute/resolve(email:hasActiveMacConnection:hostSupportsAgentSink:)``), and is NOT
    /// `#if DEBUG`-gated, so it works on Release (beta/prod) builds for the team.
    ///
    /// The structured log (the store owns ``diagnosticLog``) is a process-wide
    /// flight recorder that is never reset at the account boundary, so it is
    /// exported into the bundle on DEBUG builds only; on Release the bundle omits it
    /// to avoid a shared-device cross-account leak (see the body comment). The string
    /// snapshots are gathered by the caller on the UI layer, where the
    /// `GhosttySurfaceView`/`MobileDebugLog` accessors live. Fire-and-forget; a
    /// transport failure is logged and surfaced via the returned `Bool`.
    ///
    /// - Parameters:
    ///   - text: An optional freeform note from the user.
    ///   - debugLogText: The string debug-log snapshot (from `MobileDebugLog`).
    ///   - terminalText: The visible terminal text (from `GhosttySurfaceView`).
    ///   - buildStamp: The build-identity stamp (build type + version + OS +
    ///     device) written into the bundle. Defaults to the diagnostic log's
    ///     stamp on DEBUG builds when not supplied, and to an empty string on
    ///     Release (the sole caller always supplies a stamp).
    /// - Returns: `true` when the Mac acknowledged the bundle.
    @discardableResult
    public func submitPrivilegedAgentFeedback(
        text: String,
        debugLogText: String,
        terminalText: String,
        buildStamp: String? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        // The structured `diagnosticLog` is a process-wide flight recorder created
        // once in `AppCompositionRoot` and never reset at the account boundary. This
        // feedback path is intentionally NOT `#if DEBUG`-gated (it ships to
        // `@manaflow.ai` users on Release/TestFlight), so exporting the structured log
        // here would let a later signed-in team user submit a bundle carrying the
        // previous account's structured activity (connection/pairing/input/composer
        // timing) on a shared device. Keep the structured export DEBUG-only for the
        // dev dogfood round-trip; on Release the bundle carries only the freeform
        // note, visible terminal text, and the string debug log. (This restores the
        // pre-diagnostics-plumbing behavior: `diagnosticLog` was `nil` on Release, so
        // this already exported empty `Data()` there.)
        #if DEBUG
        let diagnosticBlob = await diagnosticLog?.export() ?? Data()
        let buildStamp = buildStamp ?? diagnosticLog?.buildStamp ?? ""
        #else
        let diagnosticBlob = Data()
        let buildStamp = buildStamp ?? ""
        #endif
        let clientID = clientID
        // Cap inputs and build the (potentially multi-MiB) combined blob +
        // base64 + JSON request OFF the main actor: the store is `@MainActor`, so
        // doing the concat/encode here would block the UI on a large bundle. A
        // detached task returns the finished request bytes (`Data` is `Sendable`).
        let request: Data?
        do {
            request = try await Task.detached(priority: .utility) { () -> Data in
                try Self.buildDogfoodFeedbackRequest(
                    text: text,
                    debugLogText: debugLogText,
                    terminalText: terminalText,
                    buildStamp: buildStamp,
                    clientID: clientID,
                    diagnosticBlob: diagnosticBlob
                )
            }.value
        } catch {
            mobileShellLog.error("dogfood feedback encode failed error=\(String(describing: error), privacy: .public)")
            return false
        }
        guard let request else { return false }
        do {
            _ = try await client.sendRequest(request)
            return true
        } catch {
            mobileShellLog.error("dogfood feedback submit failed error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Client-side caps mirroring the Mac sink, applied before any large
    /// allocation so a huge debug log or note can't be encoded into a multi-MiB
    /// request on the phone. `nonisolated` so the off-main request builder can
    /// read them.
    nonisolated private static let dogfoodFeedbackMaxTextChars = 16_384
    nonisolated private static let dogfoodFeedbackMaxTerminalChars = 262_144
    nonisolated private static let dogfoodFeedbackMaxDebugLogChars = 1_048_576

    /// Combine the structured + string diagnostics into one self-contained blob,
    /// base64-encode it, and build the RPC request — all off the main actor.
    ///
    /// The string debug log rides inside the same diagnostic file as the compact
    /// structured rows (rows, a divider, then the human-readable log) so the Mac
    /// bundle is self-contained. Inputs are size-capped first.
    nonisolated private static func buildDogfoodFeedbackRequest(
        text: String,
        debugLogText: String,
        terminalText: String,
        buildStamp: String,
        clientID: String,
        diagnosticBlob: Data
    ) throws -> Data {
        let cappedText = String(text.prefix(dogfoodFeedbackMaxTextChars))
        let cappedTerminal = String(terminalText.prefix(dogfoodFeedbackMaxTerminalChars))
        let cappedDebugLog = String(debugLogText.prefix(dogfoodFeedbackMaxDebugLogChars))
        var combined = diagnosticBlob
        if !cappedDebugLog.isEmpty {
            combined.append(Data("\n----- mobile debug log -----\n".utf8))
            combined.append(Data(cappedDebugLog.utf8))
        }
        return try MobileCoreRPCClient.requestData(
            method: "dogfood.feedback.submit",
            params: [
                "text": cappedText,
                "terminal_text": cappedTerminal,
                "build_stamp": buildStamp,
                "diagnostic_blob_base64": combined.base64EncodedString(),
                "client_id": clientID,
            ]
        )
    }
}
