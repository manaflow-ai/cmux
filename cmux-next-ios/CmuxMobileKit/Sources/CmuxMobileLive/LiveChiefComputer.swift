#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileChief
import Foundation

/// Chief info's Computer card reads the account's Cloud machines from a
/// connected Mac's `cloud-directory` (https://github.com/manaflow-ai/cmux/issues/31488).
extension LiveCoordinator: ChiefComputerSource {
    /// The capability of a host that serves the Cloud directory.
    static let cloudDirectoryCapability = "cloud-directory-v1"

    public func computerMac(preferring preferred: String?) -> ChiefComputerMac? {
        let candidates = [preferred, focusedMacID].compactMap { $0 } + linkedMacIDs.sorted()
        for macID in candidates {
            guard let session = sessions[macID], session.currentLink != nil,
                  let capabilities = store.macCapabilities[macID],
                  capabilities.contains(Self.cloudDirectoryCapability) else { continue }
            return ChiefComputerMac(macID: macID,
                                    streamsDesktop: capabilities.contains(StreamedBrowserDirectory.cloudDesktopCapability))
        }
        return nil
    }

    public func computerDirectory(on macID: String) async throws -> ChiefComputerDirectory {
        Self.computerDirectory(try await cloudDirectory(on: macID))
    }

    nonisolated static func computerDirectory(_ directory: CloudDirectory) -> ChiefComputerDirectory {
        ChiefComputerDirectory(paid: directory.paid, desktops: directory.desktops, machines: directory.machines.map {
            .init(machineID: $0.machineID, teamID: $0.teamID, name: $0.name, status: $0.status, ran: $0.ran)
        })
    }
}
#endif
