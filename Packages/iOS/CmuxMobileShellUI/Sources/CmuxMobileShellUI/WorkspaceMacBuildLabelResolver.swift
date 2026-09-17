import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell

/// Resolves workspace-provided labels before the paired-Mac cache loads.
struct WorkspaceMacBuildLabelResolver {
    private let channel: MacBuildChannel

    init(channel: MacBuildChannel = MacBuildChannel()) {
        self.channel = channel
    }

    /// Merges authoritative paired-Mac labels with workspace preview tags.
    nonisolated func labels(
        workspaces: [MobileWorkspacePreview],
        existing: [String: String]
    ) -> [String: String] {
        var labels = existing
        for workspace in workspaces {
            guard let macDeviceID = workspace.macDeviceID,
                  let instanceTag = workspace.macInstanceTag,
                  !instanceTag.isEmpty else {
                continue
            }
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
            if labels[pairingID] == nil,
               let label = channel.label(bundleID: nil, tag: instanceTag) {
                labels[pairingID] = label
            }
        }
        return labels
    }
}
