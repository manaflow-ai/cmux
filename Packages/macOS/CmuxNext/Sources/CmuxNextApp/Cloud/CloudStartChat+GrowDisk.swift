import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import os

extension CloudStartChat {
    /// Grows `machine`'s disk so the copy in `refusal` fits it (2026-11-18: "a 22 GB folder must just work on Cloud"):
    /// to the folder's needed disk (half again the folder, at least the folder and the reserve) in 4 GiB steps, at most
    /// the largest Cloud disk. A resize past the plan answers `cloud.size.locked` naming the plan's largest size; the disk
    /// is then grown to that size's largest disk only when it holds the folder (2026-11-18: "grow the Cloud machine only up
    /// to the max size the team's plan allows; if the folder still won't fit, say so clearly"), else
    /// ``CloudSeedRefusal/Growth/pastPlan(_:)``. A copy whose size is unknown, or a resize that fails otherwise, is not grown.
    func growDisk(_ machine: CloudMachineSession, for refusal: CloudSeedRefusal) async -> CloudSeedRefusal.Growth {
        guard let bytes = refusal.copyBytes, let floor = CloudChatSize.floorDiskBytes(bytes) else { return .notGrown }
        guard floor <= CloudChatSize.maxDiskBytes else { return .pastPlan(.xxl) }
        let needed = CloudChatSize.neededDiskBytes(bytes) ?? floor
        do {
            return .grown(diskMb: try await resizeDisk(machine, mb: Self.diskMb(needed, atMost: CloudChatSize.maxDiskBytes)))
        } catch {
            guard let planMax = CloudSizeLocked.of(error)?.allowed(planMax: nil) else {
                Self.growLog.error("cloud disk of \(machine.machineID, privacy: .public) not grown: \(String(describing: error), privacy: .public)")
                return .notGrown
            }
            let largest = CloudChatSize.largestDiskBytes(planMax: planMax)
            guard floor <= largest else { return .pastPlan(planMax) }
            do {
                return .grown(diskMb: try await resizeDisk(machine, mb: Self.diskMb(needed, atMost: largest)))
            } catch {
                Self.growLog.error("cloud disk of \(machine.machineID, privacy: .public) not grown within \(planMax.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                return CloudSizeLocked.of(error) == nil ? .notGrown : .pastPlan(planMax)
            }
        }
    }

    /// `bytes` in MiB, rounded up to a 4 GiB step, at most `cap` (itself a whole step).
    nonisolated static func diskMb(_ bytes: Int64, atMost cap: Int64) -> Int {
        let step: Int64 = 4 * 1_073_741_824
        let rounded = min((max(bytes, 0) + step - 1) / step * step, cap)
        return Int(rounded / 1_048_576)
    }

    private static let growLog = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud")

    /// The app server's `cloud.machine.resize` of the disk alone (`cloud resize-machine --disk`'s call); the machine's
    /// disk in MiB once it answers.
    private func resizeDisk(_ machine: CloudMachineSession, mb: Int) async throws -> Int {
        _ = try await services.cloud.machineChange("cloud.machine.resize",
                                                   ["machine": .string(machine.machineID), "size": .object(["disk_mb": .number(Double(mb))])],
                                                   allow: { true })
        return mb
    }
}
