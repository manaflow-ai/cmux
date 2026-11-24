public import CmuxNextCloud
import Foundation
import os

/// A Cloud chat start whose machine can't clone the folder from its git remote (cmux-tui
/// `link start-chat copy --on-seed-refusal ask` answering `seed_refused`): the whole folder is copied
/// instead, and the person is never asked (2026-11-10: "instead of this dialog, let's just automatically
/// do it"; 2026-11-13: "instead of asking user to copy the folder, just do it automatically so that it just
/// works"). A start that waited on the question showed only "Thinking" in its chat.
/// Only a copy the machine's disk cannot hold (``fits(diskMb:)``) is not made: the start ends with words
/// that say so, since a silent copy of a 12.8 GB folder ran a 16 GB machine's disk out ("Broken pipe").
public nonisolated struct CloudSeedRefusal: Equatable, Sendable {
    public static let code = "seed_refused"
    /// The seed plan's code for a private repository the machine can't read without the cmux GitHub App.
    public static let needsGitHub = "seed.needs_github"
    /// The start plan's code for a machine whose disk is smaller than the size the folder needs (cmux-tui
    /// `preflight::too_small`): the workspace already had that machine, so nothing is cloned or copied there.
    public static let machineTooSmall = "machine.too_small"

    /// cmux-tui's words: why the machine can't clone it, and the copy's files and size.
    public let message: String
    public let machine: String
    /// The seed plan's code for the refusal (`not_git`, `submodule_local_work`, ...), for the log.
    public let fallbackCode: String?
    /// The bytes the copy will send, as the copy itself lists them (cmux-tui `copy_estimate`): the folder whole with
    /// `.git`, or only its first pass past the copy's limits (no `.git`, at most 256 MiB), never the whole tree a first
    /// pass leaves on this Mac. Nil when cmux-tui could not read the folder's size.
    public let copyBytes: Int64?
    /// The plan's largest size when even its largest disk can't hold the copy (``Growth/pastPlan(_:)``): the start ends
    /// saying so, never growing the machine past what the plan gives.
    public var pastPlan: CloudChatSize?
    /// The disk a machine whose size is not known is taken to have (the smallest size's).
    public static let assumedDiskMb = 16_384
    /// What a machine's image and its own work keep of the disk: a copy may fill the rest.
    public static let reservedDiskBytes: Int64 = CloudChatSize.reservedDiskBytes
    /// The least a machine is taken to have room for, whatever its disk.
    public static let leastRoomBytes: Int64 = 4 * 1_073_741_824

    /// The refusal in `answer`, or nil for any other answer.
    public init?(_ answer: CloudMoveCLI.Answer, machine: String) {
        guard !answer.ok, answer.errorCode == Self.code else { return nil }
        message = answer.error ?? Self.code
        self.machine = machine
        fallbackCode = answer.fallbackCode
        copyBytes = answer.copyBytes
    }

    /// The bytes a copy may send to a machine with a `diskMb` disk (nil: ``assumedDiskMb``): the disk less the reserve
    /// (``CloudChatSize/floorDiskBytes(_:)``, never the half-again disk a start asks), at least ``leastRoomBytes``.
    public static func room(diskMb: Int?) -> Int64 {
        max(Int64(diskMb ?? assumedDiskMb) * 1_048_576 - reservedDiskBytes, leastRoomBytes)
    }

    /// Whether what the copy sends fits the machine it goes to (`diskMb`: that machine's own disk, sized for the folder
    /// by the start's preflight). A copy whose size cmux-tui could not read is made.
    public func fits(diskMb: Int?) -> Bool { (copyBytes ?? 0) <= Self.room(diskMb: diskMb) }

    /// Whether connecting GitHub lets the machine clone the folder instead: only a repository it can't read without
    /// the cmux GitHub App (``needsGitHub``). Not a folder that is not git, a submodule's local work, commits that are
    /// not on GitHub, or a remote elsewhere: connecting GitHub changes none of those.
    public var gitHubHelps: Bool { fallbackCode == Self.needsGitHub }

    /// The code the page's start card reads for a copy that does not fit (``tooLarge``): ``needsGitHub`` when
    /// connecting GitHub helps (its Connect GitHub, then Retry), else nil (the card's own failure, with Retry).
    public var pageCode: String? { gitHubHelps ? Self.needsGitHub : nil }

    /// Why a copy that does not fit is not made, for the chat: the folder's size and the machine's name, and connecting
    /// GitHub only when that helps (``gitHubHelps``).
    public var tooLarge: String {
        if let pastPlan {
            let words = String(localized: "cloud.seedRefused.pastPlan", defaultValue: "This folder is %1$@, more than the largest machine your plan gives (%2$@) has room for. Choose a smaller folder.", table: "Cloud", bundle: .localizedModule)
            let disk = ByteCountFormatter.string(fromByteCount: CloudChatSize.largestDiskBytes(planMax: pastPlan), countStyle: .file)
            return String(format: words, ByteCountFormatter.string(fromByteCount: copyBytes ?? 0, countStyle: .file), disk)
        }
        let words = gitHubHelps
            ? String(localized: "cloud.seedRefused.tooLarge", defaultValue: "This folder is %1$@, more than %2$@ has room for. Choose a smaller folder, or connect GitHub to clone it.", table: "Cloud", bundle: .localizedModule)
            : String(localized: "cloud.seedRefused.tooLargeNoGitHub", defaultValue: "This folder is %1$@, more than %2$@ has room for. Choose a smaller folder.", table: "Cloud", bundle: .localizedModule)
        return String(format: words, ByteCountFormatter.string(fromByteCount: copyBytes ?? 0, countStyle: .file), machine)
    }

    /// The start plan's refusal of a machine too small for the folder (``machineTooSmall``) as the copy's own: the folder's
    /// size and the machine's name, no Retry (the workspace's machine stays the same). Nil for any other answer.
    public static func planRefusal(_ answer: CloudMoveCLI.Answer) -> CloudMoveFailure? {
        guard answer.fallbackCode == machineTooSmall, answer.copyBytes != nil,
              let refusal = CloudSeedRefusal(answer, machine: answer.machineTitle ?? "") else { return nil }
        return CloudMoveFailure(message: refusal.tooLarge, code: refusal.pageCode)
    }

    /// What growing the machine's disk for a copy that does not fit came to (``copying(machine:diskMb:grow:declined:_:)``).
    public enum Growth: Equatable, Sendable {
        /// The disk was grown: the machine's disk is now this many MiB.
        case grown(diskMb: Int)
        /// No disk the plan gives holds the copy: the plan's largest size.
        case pastPlan(CloudChatSize)
        /// Not grown (no way to, or the resize failed): the copy is not made, as before.
        case notGrown
    }

    /// `copy` seeding first (`.ask`); a refused seed copies the folder (`.copy`) with no question. A copy that
    /// does not fit the machine's `diskMb` disk first grows the disk (`grow`, up to what the plan gives: 2026-11-18, "a 22 GB
    /// folder must just work on Cloud", "grow the Cloud machine only up to the max size the team's plan allows"); only a
    /// copy no grown disk holds is not made: `declined(refusal)` is thrown (its ``tooLarge`` and ``pageCode``).
    @MainActor public static func copying<Copied>(machine: String, diskMb: Int?,
                                                  grow: ((CloudSeedRefusal) async -> Growth)? = nil,
                                                  declined: (CloudSeedRefusal) -> any Error,
                                                  _ copy: (CloudMoveCLI.SeedRefusal) async throws -> (CloudMoveCLI.Answer, Copied)) async throws -> (CloudMoveCLI.Answer, Copied) {
        let first = try await copy(.ask)
        guard var refused = CloudSeedRefusal(first.0, machine: machine) else { return first }
        let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud")
        log.info("cloud seed refused on \(machine, privacy: .public): \(refused.fallbackCode ?? "unknown", privacy: .public); copy fits: \(refused.fits(diskMb: diskMb), privacy: .public)")
        if refused.fits(diskMb: diskMb) { return try await copy(.copy) }
        switch await grow?(refused) ?? .notGrown {
        case .grown(let grownMb) where refused.fits(diskMb: grownMb):
            log.info("cloud disk of \(machine, privacy: .public) grown to \(grownMb, privacy: .public) MiB for the copy")
            return try await copy(.copy)
        case .pastPlan(let planMax):
            refused.pastPlan = planMax
            throw declined(refused)
        case .grown, .notGrown:
            throw declined(refused)
        }
    }
}
