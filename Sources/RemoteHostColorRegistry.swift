import Foundation

/// Assigns each remote destination a color from ``hostPalette`` so servers are easy
/// to tell apart at a glance, and the same destination shows the same color in every
/// open window for the life of the app session. Gated by the
/// `remoteTmux.originColors.beta` flag at the call sites.
///
/// Keyed by the host's `destination` STRING (the ssh alias or `user@host` — the
/// "host name" the user typed), NOT the port/identity-specific ``connectionHash``.
/// That deliberately keeps one color per destination string across ports, at the
/// cost that two spellings of the same box (`box` vs `user@box`) are treated as
/// two hosts. This is a recognizability hint, not an identity — collisions are
/// expected once there are more hosts than palette colors.
///
/// Assignment rule ("hash the host name to a color; on a collision take the next
/// color"):
/// 1. `destination` is hashed with a STABLE FNV-1a string hash (not Swift's
///    per-process randomized `Hasher`) to a starting palette index — so a host
///    that never collides lands on the same color across app launches too.
/// 2. Linear-probe forward from that start to the first slot not already held by a
///    different host — the "collision → next color" behavior.
/// 3. If every slot is taken (more hosts than palette colors), fall back to the
///    hashed start and let colors repeat.
/// 4. The chosen slot is cached per destination, so repeat lookups from any window
///    return the same color.
///
/// Consistency guarantee: within one running session the cache gives a destination
/// one color in every window. Across restarts a lone host is stable (step 1), but
/// two hosts that collide on the same start can swap colors depending on which was
/// seen first. Assignments are in-memory and the cache never shrinks (stale hosts
/// keep reserving a slot); durable persistence and eviction are deliberate
/// follow-ups.
/// One instance is owned by ``RemoteTmuxController`` (itself owned by `AppDelegate`
/// at the app seam) and reached through it, so assignments stay consistent
/// process-wide without an ambient global. Tests construct their own instance with
/// an injected `slotCount` to exercise the probing deterministically.
@MainActor
final class RemoteHostColorRegistry {
    /// Sixteen soft colors picked for telling hosts apart, rather than borrowed from the
    /// workspace tab palette, whose dark reds and magentas collapse into each other once the
    /// sidebar rail brightens them (two pairs there differ by under 5). As the rail draws them,
    /// every pair differs by at least 11 in OKLab (x100), colors that are neighbors in this order
    /// differ by at least 26, so a host bumped to the next slot by a collision lands on a clearly
    /// different color, each differs from the grey sidebar (#A9A9A9) by at least 15, and from the
    /// selected row's blue by at least 12. `RemoteHostColorRegistryTests` checks those floors.
    static let hostPalette: [String] = [
        "#B1A2FA", // violet
        "#E7BB4E", // gold
        "#9B577B", // mauve
        "#75D1A3", // mint
        "#77779E", // slate
        "#FF945A", // tangerine
        "#A8EAF6", // sky
        "#F06C7F", // coral
        "#DDE2BB", // butter
        "#E18DCD", // pink
        "#8A9E2D", // olive
        "#A963C7", // purple
        "#9B6F0D", // ochre
        "#FFDAFF", // lilac
        "#259E6A", // green
        "#9E5131", // rust
    ]

    /// Number of palette slots to assign over. Defaults to ``hostPalette``'s count;
    /// tests inject other counts to exercise the probing.
    let slotCount: Int

    /// destination → assigned palette slot (the stable per-host cache).
    private(set) var slotByHost: [String: Int] = [:]
    /// palette slot → destination that holds it (drives collision probing).
    private var hostBySlot: [Int: String] = [:]

    init(slotCount: Int = RemoteHostColorRegistry.hostPalette.count) {
        self.slotCount = max(0, slotCount)
    }

    /// The palette slot for `destination`, assigning one on first sight (stable
    /// hash start + linear probe over free slots) and caching it. `nil` only when
    /// there are no slots.
    @discardableResult
    func slot(for destination: String) -> Int? {
        guard slotCount > 0 else { return nil }
        if let existing = slotByHost[destination] { return existing }
        let start = Int(Self.stableHash(destination) % UInt64(slotCount))
        var chosen = start
        for offset in 0 ..< slotCount {
            let idx = (start + offset) % slotCount
            if hostBySlot[idx] == nil {
                chosen = idx
                break
            }
        }
        slotByHost[destination] = chosen
        hostBySlot[chosen] = destination
        return chosen
    }

    /// The color hex for `destination`'s assigned slot. `nil` when the palette is empty.
    func colorHex(for destination: String) -> String? {
        guard let slot = slot(for: destination), slot < Self.hostPalette.count else { return nil }
        return Self.hostPalette[slot]
    }

    /// Stable FNV-1a/64 hash of a string — deterministic across processes (unlike
    /// `Hasher`), so a host's starting color doesn't change between app launches.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        return hash
    }
}
