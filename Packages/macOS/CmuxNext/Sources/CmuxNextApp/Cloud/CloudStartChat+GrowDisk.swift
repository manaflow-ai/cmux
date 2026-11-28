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
        let core = CloudStartCore(), floor = refusal.copyBytes.flatMap(CloudChatSize.floorDiskBytes)
        let needed = refusal.copyBytes.flatMap(CloudChatSize.neededDiskBytes) ?? floor
        var step = core.growStep(floor: floor, needed: needed, maxDisk: CloudChatSize.maxDiskBytes, answer: nil, retried: false)
        var plan: CloudChatSize?, retried = false
        while case .resize(let mb) = step {
            do {
                return .grown(diskMb: try await resizeDisk(machine, mb: mb))
            } catch {
                Self.growLog.error("cloud disk of \(machine.machineID, privacy: .public) not grown: \(String(describing: error), privacy: .public)")
                let locked = CloudSizeLocked.of(error)
                plan = plan ?? locked?.allowed(planMax: nil)
                let answer: CloudStartCore.GrowAnswer = if locked != nil, let plan { .locked(planMax: plan.rawValue, largest: CloudChatSize.largestDiskBytes(planMax: plan)) } else { .failed }
                step = core.growStep(floor: floor, needed: needed, maxDisk: CloudChatSize.maxDiskBytes, answer: answer, retried: retried)
                retried = true
            }
        }
        if case .pastPlan(let size) = step { return .pastPlan(CloudChatSize(rawValue: size) ?? .xxl) }
        return .notGrown
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
