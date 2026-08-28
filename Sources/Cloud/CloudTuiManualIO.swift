import CmuxSettings
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Everything a workspace needs to run one `--pipe-io` relay for a cloud
/// machine's cmux-tui terminal: the bundled client, the machine link's local
/// mux socket, and the daemon terminal id.
struct CloudTuiManualIOAttach: Equatable, Sendable {
    let clientPath: String
    let socketPath: String
    let terminalID: String

    @MainActor
    func makePump() -> TuiManualIOPump {
        TuiManualIOPump(
            binaryPath: clientPath,
            target: .socket(socketPath),
            terminalID: terminalID,
            // The relay only dials a local unix socket; the ambient
            // environment (PATH, HOME, TMPDIR) is all it needs, same as the
            // link client itself.
            environment: ProcessInfo.processInfo.environment
        )
    }
}

/// Gate for the cloud manual-IO data path. On (the default) a cloud
/// terminal pane renders through a manual-mirror Ghostty surface fed by
/// `attach --pipe-io`; off (or when the bundled client predates the flag)
/// it falls back to the exec attach pane running the full TUI renderer.
enum CloudTuiManualIO {
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.cloudTerminalManualIO
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// True when `client` understands `attach --pipe-io`. The bundled
    /// client comes from a rolling artifacts manifest, so a freshly built
    /// app can carry a client older than this feature; probing keeps that
    /// skew a silent fallback to the exec pane instead of a relay crash
    /// loop. One probe per client path+mtime, cached for the process.
    static func clientSupportsPipeIO(clientURL: URL) async -> Bool {
        await CloudTuiPipeIOProbe.shared.supportsPipeIO(clientURL: clientURL)
    }
}

/// Serializes `--help` probes and caches their results; an actor so the
/// child `Process` and its deadline task stay on one isolation domain (the
/// same shape as ``CloudMachineLink/run(arguments:timeout:)``).
actor CloudTuiPipeIOProbe {
    static let shared = CloudTuiPipeIOProbe()
    private var results: [String: Bool] = [:]

    func supportsPipeIO(clientURL: URL) async -> Bool {
        let path = clientURL.path
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(path)#\(mtime)"
        if let cached = results[cacheKey] {
            return cached
        }
        let supported = await probeHelp(clientURL: clientURL)
        results[cacheKey] = supported
#if DEBUG
        cmuxDebugLog("cloudTuiManualIO.probe client=\(path) supportsPipeIO=\(supported)")
#endif
        return supported
    }

    private func probeHelp(clientURL: URL) async -> Bool {
        let process = Process()
        process.executableURL = clientURL
        // The top-level help is the short index; `--pipe-io` is documented
        // only in the attach/start options help.
        process.arguments = ["attach", "--help"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { exit.resolve($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            return false
        }
        async let output = CloudLinkPipe.readToEnd(stdout.fileHandleForReading)
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            process.terminate()
        }
        _ = await exit.result
        deadline.cancel()
        let text = String(decoding: await output, as: UTF8.self)
        return text.contains("--pipe-io")
    }
}
