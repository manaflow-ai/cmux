/// The switch set a dogfood build opens with, so it works when double-clicked, with no launch environment
/// (Lawrence 2026-10-27, handoff cmux-lead-dogfood-2.md). A build whose shipped tag (the fleet's `--tag`, the bundle's
/// `CMUX_TAG`) starts with ``tagPrefix`` resolves ``names`` on by default (``FeatureOverrides/buildDefaults``), under
/// every other input, so `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` still override one launch. Every other
/// build (DEV, NIGHTLY and Release) keeps its channel defaults. Bench-only switches are never in a set: a dogfood build
/// is a Release build, which compiles them out, and a name here would be a bench-only string in the shipped app
/// (`check-no-bench-hooks.sh` refuses it: cefHelperHost and chromiumHostIdleExit left the set for that); perfLabCanary
/// delays every key press by 2 ms and perfLabKillProbe kills processes on purpose; nor are switches whose own description
/// says to turn them on later (cefLayerHostingEveryPage, hangReportsSchema3), nor chromiumAdBlockerAtFirstTab until a
/// pinned fork has the first-tab load (fork API 41): on a fork without it the feature runs no built-in ad blocker.
public nonisolated struct FeatureDogfoodSet: Sendable, Equatable {
    /// The chrome-parity dogfood builds (`chrome-parity-v2-1`, ...). From v2.2.12 (cmux-ad order 4, 2026-10-31) a switch is
    /// here only while its own journey passed with it on; it stays only when the dogfood smoke gate also passes with it
    /// on (handoff/dogfood-switch-audit.md). The 91 switches with neither a journey pass nor a smoke pass left the set;
    /// a switch whose DEV default is on stays on in these DEV-kind builds without a name here. Names this build's registry
    /// does not declare are ignored, as ``FeatureList`` ignores unknown names in any input.
    public static let chromeParity = FeatureDogfoodSet(tagPrefix: "chrome-parity-", names: [
        "controlSocketEarlyBind",
        "launchVisiblePanesOnly",
        "launchWindowsByOcclusion",
        "paneHoldsContentInMotion",
        "pointerFrameDrags",
        "resampledDrags",
        "terminalPointerFrames",
        "terminalSizingPerApp",
    ])

    /// The tag prefix of the builds this set is for.
    public let tagPrefix: String
    /// The features on by default in those builds.
    public let names: Set<String>

    public init(tagPrefix: String, names: Set<String>) {
        self.tagPrefix = tagPrefix
        self.names = names
    }

    /// The build defaults of a build that ships `tag`: ``names`` for one of this set's tags, else none.
    public func buildDefaults(forTag tag: String?) -> Set<String> {
        guard let tag, tag.hasPrefix(tagPrefix) else { return [] }
        return names
    }
}
