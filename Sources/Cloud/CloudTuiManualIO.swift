import CmuxSettings
import CmuxTuiManualIO
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Everything a workspace needs to run one `--pipe-io` relay for a cloud
/// machine's cmux-tui terminal: the bundled client, the machine link's local
/// mux socket, and the daemon terminal id.
///
/// `resolveSocketPath` is called whenever a relay is spawned. A headless
/// link can die while the pane remains alive, so retaining the first socket
/// path would make every retry reconnect to a dead Unix socket. The resolver
/// asks the link manager for the current link and therefore also recreates the
/// authenticated link when needed.
struct CloudTuiManualIOAttach: Sendable {
    let clientPath: String
    let socketPath: String
    let terminalID: String
    let resolveSocketPath: (@Sendable () async throws -> String)?

    init(
        clientPath: String,
        socketPath: String,
        terminalID: String,
        resolveSocketPath: (@Sendable () async throws -> String)? = nil
    ) {
        self.clientPath = clientPath
        self.socketPath = socketPath
        self.terminalID = terminalID
        self.resolveSocketPath = resolveSocketPath
    }

    @MainActor
    func makePump() -> TuiManualIOPump {
        let initialTarget = TuiManualIORelayTarget.socket(socketPath)
        let targetProvider: (@Sendable () async throws -> TuiManualIORelayTarget)? = resolveSocketPath.map { resolver in
            { @Sendable in
                .socket(try await resolver())
            }
        }
        return TuiManualIOPump(
            binaryPath: clientPath,
            target: initialTarget,
            terminalID: terminalID,
            // The relay only dials a local unix socket; the ambient
            // environment (PATH, HOME, TMPDIR) is all it needs, same as the
            // link client itself.
            environment: ProcessInfo.processInfo.environment,
            targetProvider: targetProvider
        )
    }
}

/// Supplies the cloud manual-IO setting and the bundled-client capability probe.
///
/// The app creates one instance at its composition root and injects it into the
/// cloud surface provider. Keeping the defaults store and probe here makes the
/// decision testable without process-wide state.
@MainActor
final class CloudTuiManualIOService {
    private let defaults: UserDefaults
    private let probe: any CloudTuiPipeIOProbing

    init(
        defaults: UserDefaults = .standard,
        probe: any CloudTuiPipeIOProbing = CloudTuiPipeIOProbe()
    ) {
        self.defaults = defaults
        self.probe = probe
    }

    /// Whether new cloud terminal panes should use the manual-mirror path.
    var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.cloudTerminalManualIO
        return Bool.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// True when `client` understands `attach --pipe-io`. The bundled
    /// client comes from a rolling artifacts manifest, so a freshly built
    /// app can carry a client older than this feature; probing keeps that
    /// skew a silent fallback to the exec pane instead of a relay crash
    /// loop. One probe per client path+mtime, cached for the process.
    func clientSupportsPipeIO(clientURL: URL) async -> Bool {
        await probe.supportsPipeIO(clientURL: clientURL)
    }
}

/// The capability-probe seam used by ``CloudTuiManualIOService``.
protocol CloudTuiPipeIOProbing: Sendable {
    func supportsPipeIO(clientURL: URL) async -> Bool
}

/// Serializes `--help` probes and caches their results; an actor so the
/// child `Process` and its deadline task stay on one isolation domain (the
/// same shape as ``CloudMachineLink/run(arguments:timeout:)``).
actor CloudTuiPipeIOProbe: CloudTuiPipeIOProbing {
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
                try await ContinuousClock().sleep(for: .seconds(10))
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
