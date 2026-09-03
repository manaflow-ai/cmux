import Foundation

/// Pure math for the per-surface libghostty `scrollback-limit` byte budget on
/// iOS, derived from the device's physical memory.
///
/// Every mounted iOS surface allocates local scrollback up to this limit
/// independently, so a fixed limit multiplies with the mounted-surface count:
/// sessions with dozens of surfaces on low-RAM devices (the top jetsam device
/// is the 3GB iPad12,1) hit the jetsam envelope long before an 8GB iPhone
/// does. Scaling the budget with RAM keeps deep scrollback on devices that can
/// afford it without letting the smallest devices pay the same per-surface
/// cost.
///
/// The budget is `min(ceiling, max(floor, physicalMemory / 256))`:
/// - `physicalMemory / 256` charges each surface at most ~0.4% of device RAM.
/// - The 16MB ceiling is the historical fixed iOS default, sized so replays
///   that hydrate the user-configurable 20k-row window still fit at wide iPad
///   grids. RAM scaling only ever lowers that value, never raises it.
/// - The 8MB floor keeps the 20k-row replay window usable (~400 bytes/row
///   average at wide grids) instead of silently dropping most of the hydrated
///   history on the smallest devices.
public enum TerminalScrollbackByteBudget {
    /// The historical fixed iOS `scrollback-limit` (bytes); never exceeded.
    public static let ceilingBytes: UInt64 = 16_000_000
    /// The lowest budget any device is given (bytes), sized against the
    /// 20k-row replay hydration window.
    public static let floorBytes: UInt64 = 8_000_000

    /// The `scrollback-limit` byte budget for a device with the given
    /// physical memory. Monotonic in `physicalMemoryBytes`.
    public static func scrollbackLimitBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        min(ceilingBytes, max(floorBytes, physicalMemoryBytes / 256))
    }
}
