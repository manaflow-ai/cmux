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

    /// cmux-tui's words: why the machine can't clone it, and the copy's files and size.
    public let message: String
    public let machine: String
    /// The seed plan's code for the refusal (`not_git`, `submodule_local_work`, ...), for the log.
    public let fallbackCode: String?
    /// The bytes the copy would send; nil when cmux-tui could not read the folder's size.
    public let copyBytes: Int64?
    /// The disk a machine whose size is not known is taken to have (the smallest size's).
    public static let assumedDiskMb = 16_384
    /// What a machine's image and its own work keep of the disk: a copy may fill the rest.
    public static let reservedDiskBytes: Int64 = 12 * 1_073_741_824
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

    /// The bytes a copy may send to a machine with a `diskMb` disk (nil: ``assumedDiskMb``).
    public static func room(diskMb: Int?) -> Int64 {
        max(Int64(diskMb ?? assumedDiskMb) * 1_048_576 - reservedDiskBytes, leastRoomBytes)
    }

    /// Whether the copy fits a machine with a `diskMb` disk. A copy whose size cmux-tui could not read is made.
    public func fits(diskMb: Int?) -> Bool { (copyBytes ?? 0) <= Self.room(diskMb: diskMb) }

    /// Why a copy that does not fit is not made, for the chat: the folder's size and the machine's name.
    public var tooLarge: String {
        String(format: String(localized: "cloud.seedRefused.tooLarge", defaultValue: "This folder is %1$@, more than %2$@ has room for. Choose a smaller folder, or connect GitHub so the machine can clone it.", table: "Cloud", bundle: .module),
               ByteCountFormatter.string(fromByteCount: copyBytes ?? 0, countStyle: .file), machine)
    }

    /// `copy` seeding first (`.ask`); a refused seed copies the folder (`.copy`) with no question. A copy that
    /// does not fit the machine's `diskMb` disk is not made: `declined(``tooLarge``)` is thrown.
    @MainActor public static func copying<Copied>(machine: String, diskMb: Int?, declined: (String) -> any Error,
                                                  _ copy: (CloudMoveCLI.SeedRefusal) async throws -> (CloudMoveCLI.Answer, Copied)) async throws -> (CloudMoveCLI.Answer, Copied) {
        let first = try await copy(.ask)
        guard let refused = CloudSeedRefusal(first.0, machine: machine) else { return first }
        Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info(
            "cloud seed refused on \(machine, privacy: .public): \(refused.fallbackCode ?? "unknown", privacy: .public); copy fits: \(refused.fits(diskMb: diskMb), privacy: .public)")
        guard refused.fits(diskMb: diskMb) else { throw declined(refused.tooLarge) }
        return try await copy(.copy)
    }
}
