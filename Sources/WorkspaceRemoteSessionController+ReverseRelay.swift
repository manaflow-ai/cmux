import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Reverse relay process management
extension WorkspaceRemoteSessionController {
    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }
        guard reverseRelayControlMasterForwardSpec == nil else { return }

        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        var relayServer: WorkspaceRemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            Self.killOrphanedRemoteSSHProcesses(
                destination: configuration.destination,
                relayPort: relayPort,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )
            let forwardSpec = "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)"

            if startReverseRelayViaControlMasterLocked(forwardSpec: forwardSpec, relayPort: relayPort) {
                cliRelayServer = relayServer
                reverseRelayStderrBuffer = ""
                do {
                    try installRemoteRelayMetadataLocked(
                        remotePath: remotePath,
                        relayPort: relayPort,
                        relayID: relayID,
                        relayToken: relayToken
                    )
                } catch {
                    debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                    stopReverseRelayLocked()
                    scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                    return
                }
                recordHeartbeatActivityLocked()
                debugLog(
                    "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                    "target=\(configuration.displayTarget) controlMaster=1"
                )
                return
            }

            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = reverseRelayArguments(relayPort: relayPort, localRelayPort: localRelayPort)
            process.environment = configuration.sshProcessEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    self?.handleReverseRelayTerminationLocked(process: terminated)
                }
            }

            try process.run()
            if let startupFailure = Self.reverseRelayStartupFailureDetail(
                process: process,
                stderrPipe: stderrPipe
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                if let relayServer {
                    relayServer.stop()
                    if cliRelayServer === relayServer {
                        cliRelayServer = nil
                    }
                }
                publishDaemonStatus(
                    .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                )
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }
            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""
            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }
            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget) controlMaster=0"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(relayPort) " +
                "error=\(error.localizedDescription)"
            )
            if let relayServer {
                relayServer.stop()
                if cliRelayServer === relayServer {
                    cliRelayServer = nil
                }
            }
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch ProcessPipeReader.readAvailableDataOrEndOfFile(from: handle) {
            case .data(let data):
                self?.queue.async {
                    guard let self else { return }
                    if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                        self.reverseRelayStderrBuffer.append(chunk)
                        if self.reverseRelayStderrBuffer.count > 8192 {
                            self.reverseRelayStderrBuffer.removeFirst(self.reverseRelayStderrBuffer.count - 8192)
                        }
                    }
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
    }

    private func handleReverseRelayTerminationLocked(process: Process) {
        guard reverseRelayProcess === process else { return }
        let stderrDetail = Self.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    private func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reverseRelayRestartWorkItem = nil
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            guard self.daemonReady else { return }
            self.startReverseRelayLocked(remotePath: self.daemonRemotePath ?? remotePath)
        }
        reverseRelayRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stopReverseRelayLocked() {
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        stopReverseRelayViaControlMasterLocked()
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        removeRemoteRelayMetadataLocked()
    }

    private func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // Fallback standalone transport when dynamic forwarding through an existing
        // control master is unavailable.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += sshCommonArguments(batchMode: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    private func startReverseRelayViaControlMasterLocked(forwardSpec: String, relayPort: Int) -> Bool {
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "forward",
            forwardSpec: forwardSpec
        ) else {
            return false
        }

        cancelStaleReverseRelayViaControlMasterLocked(relayPort: relayPort)
        do {
            var result = try sshExec(arguments: arguments, timeout: 6)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog("remote.relay.controlmaster.forwardFailed \(detail) \(debugConfigSummary())")
                guard cleanupStaleRemoteRelayListenerLocked(relayPort: relayPort) else {
                    return false
                }

                result = try sshExec(arguments: arguments, timeout: 6)
                guard result.status == 0 else {
                    let retryDetail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                        ?? "ssh exited \(result.status)"
                    debugLog("remote.relay.controlmaster.forwardRetryFailed \(retryDetail) \(debugConfigSummary())")
                    return false
                }
                reverseRelayControlMasterForwardSpec = forwardSpec
                return true
            }
            reverseRelayControlMasterForwardSpec = forwardSpec
            return true
        } catch {
            debugLog("remote.relay.controlmaster.forwardFailed \(error.localizedDescription) \(debugConfigSummary())")
            return false
        }
    }

    private func cancelStaleReverseRelayViaControlMasterLocked(relayPort: Int) {
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterCancelArguments(
            configuration: configuration,
            relayPort: relayPort
        ) else {
            return
        }
        do {
            let result = try sshExec(arguments: arguments, timeout: 4)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog("remote.relay.controlmaster.cancelStaleIgnored \(detail) \(debugConfigSummary())")
                return
            }
            debugLog("remote.relay.controlmaster.cancelStale relayPort=\(relayPort) \(debugConfigSummary())")
        } catch {
            debugLog("remote.relay.controlmaster.cancelStaleIgnored \(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func cleanupStaleRemoteRelayListenerLocked(relayPort: Int) -> Bool {
        guard let script = Self.remoteStaleRelayListenerCleanupScript(
            relayPort: relayPort,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        ) else {
            debugLog("remote.relay.remoteListener.cleanupSkipped reason=no-persistent-slot relayPort=\(relayPort)")
            return false
        }

        let command = "sh -c \(Self.shellSingleQuoted(script))"
        do {
            let result = try sshExec(
                arguments: ["-S", "none"] + sshCommonArguments(batchMode: true, dropControlPath: true) + [
                    configuration.destination,
                    command,
                ],
                timeout: 8
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog("remote.relay.remoteListener.cleanupFailed relayPort=\(relayPort) \(detail) \(debugConfigSummary())")
                return false
            }

            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty {
                debugLog("remote.relay.remoteListener.cleanupNoop relayPort=\(relayPort) \(debugConfigSummary())")
            } else {
                debugLog("remote.relay.remoteListener.cleanup relayPort=\(relayPort) \(Self.debugLogSnippet(output)) \(debugConfigSummary())")
            }
            return true
        } catch {
            debugLog("remote.relay.remoteListener.cleanupFailed relayPort=\(relayPort) \(error.localizedDescription) \(debugConfigSummary())")
            return false
        }
    }

    private func stopReverseRelayViaControlMasterLocked() {
        guard let forwardSpec = reverseRelayControlMasterForwardSpec else { return }
        reverseRelayControlMasterForwardSpec = nil
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "cancel",
            forwardSpec: forwardSpec
        ) else {
            return
        }
        _ = try? sshExec(arguments: arguments, timeout: 4)
    }

    static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading)
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

}
