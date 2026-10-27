public import CmuxNextDesign

/// Where Chromium's browser process runs (plans/cmux-next/chrome-parity/p01-process.md, task 015).
///
/// `inProcess`: in the app, through the in-process shim, the mapped framework and the external
/// message pump. `host`: in the Chromium Host app; the app maps only the remote shim, whose every
/// export is an op on the host's wire, and runs no pump. Fixed for the process: Chromium starts
/// once (``CEFRuntimeSource/backend``).
public nonisolated enum BrowserBackend: String, Sendable, Equatable {
    case inProcess
    case host
}

/// Debug Settings of the Chromium Host app: Debug and bench builds only, like the
/// host app itself (embed-cef.sh) and its Swift side, so a NIGHTLY never lists a
/// toggle for a host it does not bundle. The switch is the bench-only feature
/// `cefHelperHost` (schemas/features/features.d): on in DEV, off in NIGHTLY and
/// Release (p01-process.md task 100; NIGHTLY is task 104). ``helper`` is only its
/// local override, which ``BrowserHostSwitch`` applies. A bench build has the
/// feature so `debug.chromium_host` can measure the host (chromium-host-bench.py), but
/// never moves a tab to it: ``backend(hostEnabled:)`` stays in process there.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
public nonisolated struct BrowserHostTunables {
    public nonisolated init() {}

    /// The tunables to register: none outside Debug and bench builds.
    public static var all: [TunableDescriptor] {
        #if DEBUG || CMUX_BENCH_HOOKS
        [helper.descriptor]
        #else
        []
        #endif
    }

    /// The backend the host's switch picks: ``BrowserBackend/host`` with `cefHelperHost` on
    /// (Debug builds only), otherwise ``BrowserBackend/inProcess``. The App builds its
    /// `CEFRuntimeSource` from it once the supervisor exists (task 080); until then no tab uses it.
    public static func backend(hostEnabled: Bool) -> BrowserBackend {
        #if DEBUG
        hostEnabled ? .host : .inProcess
        #else
        .inProcess
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Debug Settings section of the host app's tunables.
    public static let section = TunableSection(id: "browserHost", title: "Chromium Host App", symbol: "macwindow.on.rectangle", order: 44)

    /// The local override of `cefHelperHost` (FeatureList step 3: DEV and NIGHTLY, below
    /// policy and the environment). Unset, the feature's own value applies: on in DEV, so a
    /// Debug build's backend is the host, and off in NIGHTLY, where `debug.chromium_host open`
    /// refuses. Its default is the DEV value, the channel of every Debug build, so Debug
    /// Settings shows what an unset toggle runs with there; off keeps Chromium in process.
    public static let helper = Tunable<Bool>.toggle(
        "browserHost.helper", section, "Chromium Host app",
        help: "Overrides the cefHelperHost feature (on in DEV, off in NIGHTLY): Chromium's browser process runs in the Chromium Host app, and debug.chromium_host can show a page over a pane. Off keeps Chromium in cmux. Debug and bench builds only.",
        default: true, code: "BrowserHostTunables.helper")
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The Chromium Host app's switch: the launch's `cefHelperHost`, with
/// ``BrowserHostTunables/helper`` as its local override (FeatureList step 3) where the launch
/// takes one: DEV and NIGHTLY, when neither policy nor the environment decided the feature.
/// Chrome reads its `chrome://flags` entries before it builds the list
/// (chrome/browser/about_flags.cc); the toggle file loads off the main thread after the
/// launch list, so the override applies here, when the switch is read, and `features.list`
/// reports ``localOverride`` the same way (source `local`).
public nonisolated struct BrowserHostSwitch: Sendable {
    /// `cefHelperHost` as the launch's feature list resolved it.
    public let launchValue: Bool
    /// Whether ``BrowserHostTunables/helper`` may override ``launchValue``.
    public let takesLocalOverride: Bool
    private let tunables: TunableStore

    public init(launchValue: Bool, takesLocalOverride: Bool, tunables: TunableStore) {
        self.launchValue = launchValue
        self.takesLocalOverride = takesLocalOverride
        self.tunables = tunables
    }

    /// The toggle's value when it is set and taken, else nil. Read with Observation tracking.
    public var localOverride: Bool? {
        takesLocalOverride ? tunables.override(BrowserHostTunables.helper.key)?.bool : nil
    }

    /// Whether the host is on. Read with Observation tracking, so a `FrameObservation` over it
    /// follows the toggle.
    public var isEnabled: Bool { localOverride ?? launchValue }
}
#endif
