internal import CmuxRemoteWorkspace
internal import Foundation

enum NativeSSHControlMasterReapAttempt: Sendable {
    case reaped
    case deferred(String)
    case ignored(String)
}

@concurrent
func runNativeSSHControlMasterReap(
    metadataProbeRequest: RemoteProcessRequest,
    exitRequest: RemoteProcessRequest,
    processRunner: any RemoteSessionProcessRunning
) async -> NativeSSHControlMasterReapAttempt {
    let cancellation = RemoteProcessCancellationOperation()
    return await withTaskCancellationHandler {
        guard !Task.isCancelled else {
            return .deferred("control-master reap cancelled")
        }
        do {
            let probe = try processRunner.run(
                metadataProbeRequest,
                operation: cancellation
            )
            guard probe.status == 0 else {
                let detail = nativeSSHControlMasterReapErrorLine(
                    stderr: probe.stderr,
                    stdout: probe.stdout
                ) ?? "ssh exited \(probe.status)"
                return probe.status == 64
                    ? .ignored("relay metadata did not match")
                    : .deferred(
                        "could not verify relay metadata: \(detail)"
                    )
            }
            guard !Task.isCancelled else {
                return .deferred("control-master reap cancelled")
            }
            let exit = try processRunner.run(
                exitRequest,
                operation: cancellation
            )
            guard exit.status == 0 else {
                let detail = nativeSSHControlMasterReapErrorLine(
                    stderr: exit.stderr,
                    stdout: exit.stdout
                ) ?? "ssh exited \(exit.status)"
                return .ignored(
                    "control-master exit failed: \(detail)"
                )
            }
            return .reaped
        } catch {
            return .deferred(error.localizedDescription)
        }
    } onCancel: {
        cancellation.cancel()
    }
}

private func nativeSSHControlMasterReapErrorLine(
    stderr: String,
    stdout: String
) -> String? {
    for text in [stderr, stdout] {
        if let line = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }) {
            return line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
    }
    return nil
}
