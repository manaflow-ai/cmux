public import Foundation

/// How many bytes one ``HomeController``'s caches may keep: its row bitmaps and its decoded attachment
/// pictures. The host sizes it (the Mac from its memory budget, iOS from the device's memory), so the
/// render core has no cache size of its own.
///
/// Text measurements are not capped by it: they follow the loaded transcript, every commit reads them, and
/// the controller reports them (``HomeController/measurementBytes``) without dropping them.
///
/// ```swift
/// controller.memoryBudget = HomeMemoryBudget(bytes: share)
/// ```
public struct HomeMemoryBudget: Hashable, Sendable {
    /// The bytes the controller's bitmap and picture caches keep together, at most.
    public let bytes: Int

    /// Makes a budget of `bytes` (negative counts as 0).
    ///
    /// - Parameter bytes: The bytes the caches keep together, at most.
    public init(bytes: Int) {
        self.bytes = max(0, bytes)
    }

    /// A budget that keeps nothing: what is drawn still reaches the rows that asked for it.
    public static let zero = HomeMemoryBudget(bytes: 0)

    /// The budget for a device with `physicalMemory` bytes of memory: clamp(MiB / 64, 64, 256) MiB, the
    /// size the Mac gives all its Home render caches (`SubsystemBudget.homeRenderBitmapBytes`), for a host
    /// with one transcript on screen.
    ///
    /// - Parameter physicalMemory: The device's physical memory in bytes.
    /// - Returns: The budget.
    public static func forDevice(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> HomeMemoryBudget {
        let mebibytes = Int(clamping: physicalMemory >> 20)
        return HomeMemoryBudget(bytes: min(max(mebibytes / 64, 64), 256) << 20)
    }

    /// The row bitmaps' part: two thirds (a screen of rows and the screens around it).
    var rowBitmapBytes: Int {
        bytes / 3 * 2
    }

    /// The decoded pictures' part: the rest.
    var pictureBytes: Int {
        bytes - rowBitmapBytes
    }
}
