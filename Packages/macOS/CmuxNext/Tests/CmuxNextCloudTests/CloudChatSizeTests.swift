@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud chat's machine is sized for its folder: the smallest of the ladder (sm 16, md 32, lg 64, xl 128 GiB of disk)
/// whose disk holds what the copy sends and the 12 GiB the machine keeps, the same rule as cmux-tui's preflight
/// (`needed_size`). A folder past `xl` is refused as too big, never copied in part and shown as complete.
@Suite struct CloudChatSizeTests {
    let gib: Int64 = 1_073_741_824

    @Test func theNeededSizeIsTheSmallestDiskWithRoom() {
        #expect(CloudChatSize.needed(bytes: 0) == .sm)
        #expect(CloudChatSize.needed(bytes: 4 * gib) == .sm)
        #expect(CloudChatSize.needed(bytes: 4 * gib + 1) == .md)
        #expect(CloudChatSize.needed(bytes: 52 * gib) == .lg)
        #expect(CloudChatSize.needed(bytes: 116 * gib) == .xl)
        #expect(CloudChatSize.needed(bytes: 116 * gib + 1) == nil)
        #expect(CloudChatSize.needed(bytes: .max) == nil)
        // The chat size goes as no size, so an older server is unaffected.
        #expect(CloudChatSize.sm.requested == nil && CloudChatSize.lg.requested == "lg")
    }

    @Test func aRepositoryIsSizedFromItsListedSize() {
        #expect(CloudChatSize.forRepository(sizeKb: nil) == .sm)
        #expect(CloudChatSize.forRepository(sizeKb: 1_000) == .sm)
        #expect(CloudChatSize.forRepository(sizeKb: 10 * 1_048_576) == .md)
        #expect(CloudChatSize.forRepository(sizeKb: 200 * 1_048_576) == nil)
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
        let top = try #require(CloudSizeLocked.of(CloudAppOpFailure(code: "cloud.size.locked", message: "", details: .object(["plan": .null]))))
        #expect(top.upgrade == nil)
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
        let xl = CloudMachineRequest(startChatKey: "k", sizedFor: nil, team: nil, size: .xl)
        #expect(xl.atLeast(cpu: 4, memoryMb: 16_384, diskMb: 65_536) == (16, 32_768, 131_072))
    }
}
