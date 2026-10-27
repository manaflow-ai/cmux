package import CmuxNextDesign

/// Debug Settings of browser tab hibernation (DEV and NIGHTLY; Release and RC never activate
/// the store, so they keep the defaults). English developer text, as every Debug Settings section.
package struct HibernationTunables {
    package init() {}
    package static let section = TunableSection(id: "hibernation", title: "Tab Hibernation", symbol: "moon.zzz", order: 49)

    /// On (the default): each hibernated page keeps its last frame JPEG-compressed in its own
    /// 64 MB store (`HibernationSnapshots`), so every hibernated tab wakes to its picture. Off:
    /// the frame is scaled to a quarter of the shared 32 MB preview cache, as before PR 23083,
    /// and only the last few hibernated tabs keep one.
    package static let compressedSnapshots = Tunable<Bool>.toggle(
        "hibernation.compressedSnapshots", section, "Keep every hibernated tab's picture",
        help: "Each hibernated page keeps its last frame as a JPEG in its own 64 MB store, so every hibernated tab wakes to its picture. Off keeps decoded frames in the shared 32 MB preview cache, where only the last few fit (applies to the next hibernation).",
        default: true, code: "HibernationTunables.compressedSnapshots")

    package static var all: [TunableDescriptor] { [compressedSnapshots.descriptor] }
}
