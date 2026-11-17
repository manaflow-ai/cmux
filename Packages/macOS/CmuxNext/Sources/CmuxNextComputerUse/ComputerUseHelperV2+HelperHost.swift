// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// cmux Computer Use (docs/computer-use-helper.md): when the App sets ``ComputerUseHelperV2/helperHost``,
/// Computer Use runs as cmux Computer Use's worker (the one process that holds the grants) instead
/// of a helper this app starts; the control lines, consent link, endpoint and acpmux
/// admission are the same.
extension ComputerUseHelperV2 {
    /// The worker through cmux Computer Use: the host checked its signature at start and runs it as
    /// its own child, so this app checks the host's pid on the consent link.
    func applyHelperHost(_ helperHost: any ComputerUseHelperHostSpawning, generation current: Int) async {
        guard ComputerUseHelperDaemon.makePrivateDirectory((directory as NSString).deletingLastPathComponent),
              ComputerUseHelperDaemon.makePrivateDirectory(directory) else {
            return unavailable("\(directory) is not a private directory of this user")
        }
        unlink(endpointPath)
        let channel: ComputerUseHelperHostChannel
        do { channel = try await helperHost.openComputerUse() } catch {
            guard current == generation else { return }
            return unavailable("cmux Computer Use did not start Computer Use: \(error)")
        }
        let worker = HelperHostWorkerChild(channel)
        guard current == generation else {
            worker.child.closeInput()
            return
        }
        spawner = HelperHostWorkerSpawner(exited: worker.exited)
        await configureStarted(worker.child, executable: channel.executable, generation: current)
    }

}
