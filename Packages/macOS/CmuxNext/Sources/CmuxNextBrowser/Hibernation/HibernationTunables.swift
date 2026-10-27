package import CmuxNextDesign

/// Debug Settings of browser tab hibernation (DEV and NIGHTLY; Release and RC never activate
/// the store, so they keep the defaults). English developer text, as every Debug Settings section.
package struct HibernationTunables {
    package init() {}
    package static let section = TunableSection(id: "hibernation", title: "Tab Hibernation", symbol: "moon.zzz", order: 49)

    /// The developer's local override of the feature `compressedSnapshots`
    /// (`schemas/features/features.d/compressedSnapshots.json`, which `replaces` this key, on by
    /// default): nothing reads it here. The launch's feature ladder takes it from the Debug Settings
    /// file as step 3 (`FeatureLaunchLocalOverrides`; DEV and NIGHTLY, under managed policy
    /// and `CMUX_DISABLE_FEATURES`/`CMUX_ENABLE_FEATURES`), so a change applies at the next launch. On: each hibernated
    /// page keeps its last frame JPEG-compressed in its own 64 MB store (`HibernationSnapshots`).
    /// Off: the frame is scaled to a quarter of that store, as before PR 23083.
    package static let compressedSnapshots = Tunable<Bool>.toggle(
        "hibernation.compressedSnapshots", section, "Keep every hibernated tab's picture",
        help: "Overrides the feature compressedSnapshots: each hibernated page keeps its last frame as a JPEG in its own 64 MB store, so every hibernated tab wakes to its picture. Off keeps decoded frames, where only the last few fit (applies at the next launch).",
        default: true, code: "HibernationTunables.compressedSnapshots")

    package static var all: [TunableDescriptor] { [compressedSnapshots.descriptor] }
}
