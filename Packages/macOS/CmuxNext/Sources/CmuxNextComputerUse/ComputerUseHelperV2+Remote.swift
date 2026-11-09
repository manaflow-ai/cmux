// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// cmux Remote (docs/cmux-remote.md): when the App sets ``ComputerUseHelperV2/remote``,
/// Computer Use runs as cmux Remote's worker (the one process that holds the grants) instead
/// of a helper this app starts; the control lines, consent link, endpoint and acpmux
/// admission are the same.
extension ComputerUseHelperV2 {
    /// The worker through cmux Remote: the host checked its signature at start and runs it as
    /// its own child, so this app checks the host's pid on the consent link.
    func applyRemote(_ remote: any ComputerUseRemoteSpawning, generation current: Int) async {
        guard ComputerUseHelperDaemon.makePrivateDirectory((directory as NSString).deletingLastPathComponent),
              ComputerUseHelperDaemon.makePrivateDirectory(directory) else {
            return unavailable("\(directory) is not a private directory of this user")
        }
        unlink(endpointPath)
        let channel: ComputerUseRemoteChannel
        do { channel = try await remote.openComputerUse() } catch {
            guard current == generation else { return }
            return unavailable("cmux Remote did not start Computer Use: \(error)")
        }
        let worker = RemoteWorkerChild(channel)
        guard current == generation else {
            worker.child.closeInput()
            return
        }
        spawner = RemoteWorkerSpawner(exited: worker.exited)
        await configureStarted(worker.child, executable: channel.executable, generation: current)
    }

}
