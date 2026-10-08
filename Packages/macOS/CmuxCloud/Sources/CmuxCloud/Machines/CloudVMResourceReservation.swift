import Foundation

/// A machine's compute share in the subscription resource pool.
public struct CloudVMResourceReservation: Equatable, Sendable {
    public init(vcpus: Int, memoryMb: Int, diskMb: Int? = nil) {
        self.vcpus = vcpus
        self.memoryMb = memoryMb
        self.diskMb = diskMb
    }

    public let vcpus: Int
    public let memoryMb: Int
    /// The per-machine disk reservation, when the API includes it. Disk does
    /// not draw from the shared compute pool, but it is useful for grow-only
    /// menu state when guest stats are stale.
    public let diskMb: Int?
}
