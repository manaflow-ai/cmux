public import CmuxNextActions
import Foundation

/// `cloud resize-machine`'s grow (POST /api/vm/{id}/resize): `--size small|medium|large|xlarge`
/// (vCPUs and memory), `--disk GIB` (the disk's new size in whole GiB), or both in one call.
/// The disk must be a whole number of GiB in 4 GiB steps up to 256, as the server takes it (so
/// the MiB conversion never overflows); growing only is the server's check.
public struct CloudResizeRequest: Equatable, Sendable {
    /// `size` choices -> (vCPUs, MiB). Pro allows up to 24 GiB.
    public static let sizes: [String: (cpu: Int, memoryMb: Int)] = [
        "small": (2, 4096), "medium": (4, 8192), "large": (8, 16384), "xlarge": (16, 24576),
    ]

    /// `--disk` bounds in GiB (the route's `VM_DISK_MB_MAX`); it takes 4 GiB steps.
    public static let diskRange = 4...256

    public private(set) var size: String?
    public private(set) var cpu: Int?
    public private(set) var memoryMb: Int?
    public private(set) var diskGiB: Int?
    public var storageMb: Int? { diskGiB.map { $0 * 1024 } }

    /// Reads `size` and `disk` from `invocation`; at least one. A refusal is an ``ActionFailure``.
    public init(_ invocation: ActionInvocation) throws {
        let names = Self.sizes.keys.sorted().joined(separator: ", ")
        if let value = invocation["size"] {
            guard let size = value.stringValue, let (cpu, memory) = Self.sizes[size] else {
                throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(names))
            }
            (self.size, self.cpu, self.memoryMb) = (size, cpu, memory)
        }
        if let value = invocation["disk"] {
            // A bare `--disk` (no value) arrives as `true`: refused like any other non-number.
            let disk = value.intValue ?? value.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 10) }
            guard let disk, Self.diskRange.contains(disk), disk % 4 == 0 else { throw ActionFailure(message: CloudStrings.resizeNeedsSizeOrDisk(names)) }
            diskGiB = disk
        }
        guard size != nil || diskGiB != nil else { throw ActionFailure(message: CloudStrings.resizeNeedsSizeOrDisk(names)) }
    }

    /// What a CLI or agent run answers besides the machine's id: `size` and `disk_gib` as given.
    public var fields: [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [:]
        if let size { fields["size"] = .string(size) }
        if let diskGiB { fields["disk_gib"] = .int(diskGiB) }
        return fields
    }
}
