@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud chat's machine is sized for its folder: the size asked and every refusal keep the floor (the folder and the
/// 12 GiB the machine keeps); with the plan known, the size's disk grows toward half again what the copy sends. The same
/// rules as cmux-tui's preflight (`needed_disk`, `floor_disk`, `planned_size`, `grown_disk_gib`). A folder too big is
/// refused, never copied in part and shown as complete.
@Suite struct CloudChatSizeTests {
    let gib: Int64 = 1_073_741_824

    /// The floor is the folder and the reserve; the needed disk half again the folder, at least the floor: the reserve
    /// decides up to 24 GiB of folder; half a byte rounds up.
    @Test func theNeededDiskIsHalfAgainTheFolderAndAtLeastTheFloor() {
        #expect(CloudChatSize.floorDiskBytes(0) == 12 * gib)
        #expect(CloudChatSize.floorDiskBytes(116 * gib) == 128 * gib)
        #expect(CloudChatSize.floorDiskBytes(.max) == nil)
        #expect(CloudChatSize.neededDiskBytes(0) == 12 * gib)
        #expect(CloudChatSize.neededDiskBytes(4 * gib) == 16 * gib)
        #expect(CloudChatSize.neededDiskBytes(24 * gib) == 36 * gib)
        #expect(CloudChatSize.neededDiskBytes(40 * gib) == 60 * gib)
        #expect(CloudChatSize.neededDiskBytes(40 * gib + 1) == 60 * gib + 2)
        #expect(CloudChatSize.neededDiskBytes(.max) == nil)
    }

    /// With no plan known, a start asks what it did before the half-again target: the smallest size whose own disk holds
    /// the folder and the reserve, none past `xl`'s 116 GiB (cmux-tui `needed_size`, the same cases).
    @Test func theNeededSizeIsTheSmallestWhoseDiskHoldsTheFloor() {
        #expect(CloudChatSize.needed(bytes: 0) == .sm)
        #expect(CloudChatSize.needed(bytes: 4 * gib) == .sm)
        #expect(CloudChatSize.needed(bytes: 4 * gib + 1) == .md)
        #expect(CloudChatSize.needed(bytes: 20 * gib) == .md)
        #expect(CloudChatSize.needed(bytes: 20 * gib + 1) == .lg)
        #expect(CloudChatSize.needed(bytes: 48 * gib) == .lg)
        #expect(CloudChatSize.needed(bytes: 52 * gib) == .lg)
        #expect(CloudChatSize.needed(bytes: 52 * gib + 1) == .xl)
        #expect(CloudChatSize.needed(bytes: 100 * gib) == .xl)
        #expect(CloudChatSize.needed(bytes: 116 * gib) == .xl)
        #expect(CloudChatSize.needed(bytes: 116 * gib + 1) == nil)
        #expect(CloudChatSize.needed(bytes: .max) == nil)
        // The chat size goes as no size, so an older server is unaffected.
        #expect(CloudChatSize.sm.requested == nil && CloudChatSize.lg.requested == "lg")
    }

    /// No plan known: the needed size, its own disk, exactly as before.
    @Test func aStartWithNoPlanKnownAsksTheNeededSizeAndGrowsNothing() {
        #expect(CloudChatSize.planned(bytes: 48 * gib, planMax: nil) == .lg)
        #expect(CloudChatSize.grownDiskMb(.lg, bytes: 48 * gib, planMax: nil) == nil)
        #expect(CloudChatSize.planned(bytes: 100 * gib, planMax: nil) == .xl)
        #expect(CloudChatSize.grownDiskMb(.xl, bytes: 100 * gib, planMax: nil) == nil)
        #expect(CloudChatSize.planned(bytes: 117 * gib, planMax: nil) == nil)
    }

    /// Under a plan known by its largest size: the needed size when the plan gives it, its disk grown toward half again
    /// the folder within the plan's disk; else the plan's largest size grown when the plan's disk holds the floor; else
    /// the size past the plan, which the server refuses with its upgrade (cmux-tui `planned_size` and `grown_disk_gib`,
    /// the same cases).
    @Test func aPlanKnownAsksTheNeededSizeOrItsLargestGrown() {
        struct Ask: Equatable {
            var size: CloudChatSize?
            var diskGib: Int?
        }
        func ask(_ bytes: Int64, _ planMax: CloudChatSize) -> Ask {
            let size = CloudChatSize.planned(bytes: bytes, planMax: planMax)
            return Ask(size: size, diskGib: CloudChatSize.grownDiskMb(size, bytes: bytes, planMax: planMax).map { $0 / 1_024 })
        }
        #expect(CloudChatSize.largestDiskBytes(planMax: .lg) == 128 * gib && CloudChatSize.largestDiskBytes(planMax: .xxl) == 256 * gib)
        #expect(CloudChatSize.largestDiskBytes(planMax: .md) == 32 * gib)
        // cmux NEXT Pro (`lg`, 128 GiB at most): 48 GiB is `lg` (60 GiB of floor), grown to 72.
        #expect(ask(48 * gib, .lg) == Ask(size: .lg, diskGib: 72))
        // 60 GiB needs `xl` by the floor, past the plan: `lg` grown to 92 (90 rounded up).
        #expect(ask(60 * gib, .lg) == Ask(size: .lg, diskGib: 92))
        // 100 GiB: a 112 GiB floor within Pro's 128; half again is 150, capped at 128.
        #expect(ask(100 * gib, .lg) == Ask(size: .lg, diskGib: 128))
        // 120 GiB: a 132 GiB floor past Pro's 128: the size past the plan, refused with its upgrade.
        #expect(ask(120 * gib, .lg) == Ask(size: .xxl, diskGib: nil))
        // cmux NEXT Max (`2xl`, 256 GiB at most): 90 GiB is `xl` (102 of floor), grown to 136.
        #expect(ask(90 * gib, .xxl) == Ask(size: .xl, diskGib: 136))
        // 200 GiB: a 212 GiB floor past every size's own disk: `2xl` grown to 256 (300 capped).
        #expect(ask(200 * gib, .xxl) == Ask(size: .xxl, diskGib: 256))
        #expect(ask(244 * gib + 1, .xxl) == Ask(size: nil, diskGib: nil) && CloudChatSize.planned(bytes: 244 * gib + 1, planMax: .lg) == nil)
        // Within the plan, small: the needed size, its own disk enough.
        #expect(ask(10 * gib, .lg) == Ask(size: .md, diskGib: nil))
        // A plan whose largest is `md` grows nothing: past its floor, the size the plan refuses.
        #expect(ask(20 * gib, .md) == Ask(size: .md, diskGib: nil) && ask(30 * gib, .md) == Ask(size: .lg, diskGib: nil))
    }

    /// A grown disk is rounded up to 4 GiB, at most the plan's largest; no plan, no size or unknown bytes grow nothing.
    @Test func aGrownDiskRoundsUpToFourGiBWithinThePlan() {
        func grown(_ size: CloudChatSize?, _ bytes: Int64?, _ planMax: CloudChatSize?) -> Int? {
            CloudChatSize.grownDiskMb(size, bytes: bytes, planMax: planMax)
        }
        #expect(grown(.lg, 45 * gib, .lg) == 68 * 1_024)
        #expect(grown(.xxl, 100 * gib, .xxl) == 152 * 1_024)
        #expect(grown(.lg, 50 * gib, .md) == nil && grown(.xxl, 120 * gib, .lg) == nil)
        #expect(grown(.xl, 80 * gib, .xxl) == nil && grown(.lg, 50 * gib, nil) == nil)
        #expect(grown(nil, 50 * gib, .lg) == nil && grown(.lg, nil, .lg) == nil)
    }

    @Test func aRepositoryIsSizedFromItsListedSize() {
        #expect(CloudChatSize.forRepository(sizeKb: nil) == .sm)
        #expect(CloudChatSize.forRepository(sizeKb: 1_000) == .sm)
        #expect(CloudChatSize.forRepository(sizeKb: 10 * 1_048_576) == .md)
        #expect(CloudChatSize.forRepository(sizeKb: 100 * 1_048_576) == .xl)
        #expect(CloudChatSize.forRepository(sizeKb: 117 * 1_048_576) == nil)
    }

    @Test func thePreflightAnswersTheSizeOrRefuses() throws {
        let passed = CloudMoveCLI.StartChatPreflight(answer: ["ok": true, "estimate_bytes": 18 * gib, "needed_size": "md"])
        #expect(passed == .passed(bytes: 18 * gib, size: .md))
        #expect(try passed.size(folder: "~/p") == .md)
        // An older cmux-tui (no size) or a folder it could not read: the chat size.
        #expect(try CloudMoveCLI.StartChatPreflight(answer: ["ok": true]).size(folder: "~/p") == nil)
        // Past the largest size: the start card's folder-too-big, with the folder and its bytes.
        let tooBig = CloudMoveCLI.StartChatPreflight(answer: ["ok": true, "estimate_bytes": 200 * gib, "needed_size": NSNull()])
        #expect(throws: CloudMoveCLI.StartChatPreflightRefusal.self) { try tooBig.size(folder: "~/huge") }
        do { _ = try tooBig.size(folder: "~/huge") } catch let refusal as CloudMoveCLI.StartChatPreflightRefusal {
            #expect(refusal.folder == "~/huge" && refusal.bytes == Double(200 * gib))
        }
        #expect(CloudMoveCLI.shownFolder("/Users/me/Projects", home: "/Users/me") == "~/Projects")
        #expect(CloudMoveCLI.shownFolder("/Volumes/x", home: "/Users/me") == "/Volumes/x")
    }

    @Test func aSizeRefusalIsReadFromTheServerAndNamesItsUpgrade() async throws {
        let server = CloudAppOpFailure(code: "cmux.cloud.size_locked", message: "this size needs another plan",
                                       details: .object(["memory_mb": .number(32_768), "plan": .string("max")]))
        let locked = try #require(CloudSizeLocked.of(server))
        #expect(locked.needed == .xl && locked.upgrade == "max")
        #expect(locked.allowed(planMax: nil) == .lg)
        #expect(locked.allowed(planMax: .md) == .md)
        // A plan no upgrade lifts says so (null), never a guessed plan.
        let top = try #require(CloudSizeLocked.of(CloudAppOpFailure(code: "cloud.size.locked", message: "", details: .object(["upgrade_plan": .null]))))
        #expect(top.upgrade == nil)
        // The team's own plan is never read as the upgrade: a Pro team past its sizes is offered Max.
        #expect(CloudSizeLocked(details: .object(["needed": .string("xl"), "plan": .string("pro")])).upgrade == "max")
        // No server plan: the plan whose machines reach the size.
        #expect(CloudSizeLocked(needed: .lg).upgrade == "pro" && CloudSizeLocked(needed: .xl).upgrade == "max")
        #expect(CloudSizeLocked.of(CloudAppOpFailure(code: "cmux.cloud.plan_required", message: "")) == nil)
        // The platform's 403: its sizes and upgrade win over what the memory says.
        let platform = CloudAppOpFailure(code: "cloud.size.locked", message: "", details: .object([
            "memory_mb": .number(32_768), "needed": .string("2xl"), "allowed": .string("xl"), "upgrade_plan": .null, "plan": .string("max"),
        ]))
        #expect(CloudSizeLocked.of(platform) == CloudSizeLocked(upgradeNamed: true, needed: .xxl, allowed: .xl))
        #expect(CloudSizeLocked.of(platform)?.allowed(planMax: .md) == .xl)
        // cmux-tui's workspace-machine line: `nothing` for null; no details is a refusal that names nothing.
        #expect(CloudSizeLocked(details: .object(["needed": .string("xl"), "upgrade_plan": .string("nothing")])).upgrade == nil)
        #expect(CloudSizeLocked(details: .object(["upgrade_plan": .string("max"), "allowed": .string("lg")]))
            == CloudSizeLocked(upgradePlan: "max", upgradeNamed: true, allowed: .lg))
        #expect(CloudSizeLocked(details: nil) == CloudSizeLocked())
        // cmux NEXT's own plans lift it as themselves: NEXT Max past NEXT Pro's largest (`lg`).
        let next = CloudSizeLocked(details: .object(["needed": .string("xl"), "upgrade_plan": .string("next_max")]))
        #expect(next.upgrade == "next_max" && next.allowed(planMax: nil) == .lg)
        #expect(CloudSizeLocked(details: .object(["upgrade_plan": .string("next_pro")])).upgrade == "next_pro")
        #expect(CloudSizeLocked(details: .object(["upgrade_plan": .string("ultra")])).upgrade == nil)
        // The start names its size and folder on a refusal that came without them.
        await #expect(throws: CloudSizeLocked(needed: .md, folderBytes: 9)) {
            try await CloudSizeLocked.naming(.md, bytes: 9) { () async throws -> Int in throw CloudSizeLocked() }
        }
    }

    /// The app's own create (no workspace machine) asks at least the chat size's axes, never less than its default.
    @Test func theAppsCreateAsksAtLeastTheChatSize() {
        let plain = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil)
        #expect(plain.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536) == (4, 16_384, 65_536))
        let md = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil, size: .md)
        #expect(md.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536) == (4, 16_384, 65_536))
        let xl = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil, size: .xl, planMax: .xxl)
        #expect(xl.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536) == (16, 32_768, 131_072))
        // A team start grows the disk as the workspace machine's ensure does: cmux NEXT Max, 90 GiB, `xl` at 136 GiB.
        let grown = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil, size: .xl,
                                        diskMb: CloudChatSize.grownDiskMb(.xl, bytes: 90 * gib, planMax: .xxl), planMax: .xxl, bytes: 90 * gib)
        #expect(grown.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536) == (16, 32_768, 136 * 1_024))
    }

    /// The create a start sends for `folder` GiB under `planMax`, on the default machine (4 vCPU, 16 GB, 64 GB).
    func asked(folder: Int64, planMax: CloudChatSize?) throws -> (cpu: Int, memoryMb: Int, diskMb: Int) {
        let size = try #require(CloudChatSize.planned(bytes: folder * gib, planMax: planMax))
        let request = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil, size: size,
                                          diskMb: CloudChatSize.grownDiskMb(size, bytes: folder * gib, planMax: planMax), planMax: planMax, bytes: folder * gib)
        return request.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536)
    }

    /// A plan capped at 4 vCPU (its largest size `md`): a folder that needs a larger disk gets the disk and stays at
    /// 4 vCPU. It asked `lg`'s 8 or `xl`'s 16 vCPU, which the server refuses with the upgrade though the disk is the plan's.
    @Test func aLargeFolderOnAPlanCappedAtFourVCPUAsksFourVCPUAndALargerDisk() throws {
        #expect(try asked(folder: 30, planMax: .md) == (4, 16_384, 65_536))
        #expect(try asked(folder: 60, planMax: .md) == (4, 16_384, 131_072))
    }

    /// An automatic size never asks more vCPUs or memory than the plan's largest size has, never less than the default
    /// machine on any axis, and its disk still holds the folder. With no plan known only the disk is raised.
    @Test(arguments: [Int64(1), 10, 21, 30, 52, 53, 60, 90, 116], [CloudChatSize?.none, .sm, .md, .lg, .xl, .xxl])
    func anAutomaticSizeStaysWithinThePlanAndAboveTheDefault(folder: Int64, planMax: CloudChatSize?) throws {
        let size = try asked(folder: folder, planMax: planMax)
        #expect(size.cpu >= 4 && size.memoryMb >= 16_384 && size.diskMb >= 65_536, "below the default machine")
        #expect(size.cpu <= max(4, planMax?.cpu ?? 4), "\(size.cpu) vCPU on \(planMax?.rawValue ?? "no plan")")
        #expect(size.memoryMb <= max(16_384, planMax?.memoryMb ?? 16_384), "\(size.memoryMb) MB on \(planMax?.rawValue ?? "no plan")")
        #expect(Int64(size.diskMb) * 1_048_576 >= (folder + 12) * gib, "the disk asked does not hold the folder")
    }

    /// A folder no disk asked holds keeps its size's whole row: the server refuses that create with the upgrade, where a
    /// create within the plan would make a machine the folder cannot be copied to.
    @Test func aFolderPastThePlansDiskStillAsksTheSizeTheServerRefuses() throws {
        #expect(try asked(folder: 120, planMax: .md) == (32, 65_536, 131_072))
    }
}
