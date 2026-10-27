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
/// `cefHelperHost` (schemas/features/features.d); ``helper`` is only its local
/// override, which ``BrowserHostSwitch`` applies. A bench build has the
/// feature so `debug.chromium_host` can measure the host (chromium-host-bench.py), but
/// never moves a tab to it: ``backend(hostEnabled:)`` stays in process there. Tabs move to the
/// host only with the bench-only feature `chromiumHostTabs` too (``tabs`` is its local override),
/// so a run that measures in-process tabs beside `debug.chromium_host` keeps them in process.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
public nonisolated struct BrowserHostTunables {
    public nonisolated init() {}

    /// The tunables to register: none outside Debug and bench builds.
    public static var all: [TunableDescriptor] {
        #if DEBUG || CMUX_BENCH_HOOKS
        [helper.descriptor, tabs.descriptor]
        #else
        []
        #endif
    }

    /// The backend the host's switch picks: ``BrowserBackend/host`` with `cefHelperHost` and
    /// `chromiumHostTabs` on (Debug builds only), otherwise ``BrowserBackend/inProcess``. The App
    /// builds its `CEFRuntimeSource` from it at launch, with the host's supervisor in host mode (task 080).
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
    /// policy and the environment). Unset, the feature's own value applies (off on every channel):
    /// `debug.chromium_host open` refuses. On: it shows a Chromium page whose browser process
    /// runs in the Chromium Host app, over a pane.
    public static let helper = Tunable<Bool>.toggle(
        "browserHost.helper", section, "Chromium Host app",
        help: "Overrides the cefHelperHost feature: lets debug.chromium_host show a Chromium page whose browser process runs in the Chromium Host app. Chromium tabs stay in cmux unless Chromium tabs in the host is on too. Debug and bench builds only.",
        default: false, code: "BrowserHostTunables.helper")

    /// The local override of `chromiumHostTabs`, read at launch (the feature `replaces` it). With
    /// ``helper`` on too, every Chromium tab of the next launch, of every profile, runs in the one
    /// Chromium Host (`ChromiumHostSupervisor`, task 080 of plans/cmux-next/chrome-parity/p01-process.md).
    public static let tabs = Tunable<Bool>.toggle(
        "browserHost.tabs", section, "Chromium tabs in the host",
        help: "Overrides the chromiumHostTabs feature: with the Chromium Host app on too, every Chromium tab of the next launch runs in its one host. Debug builds only.",
        default: false, code: "BrowserHostTunables.tabs")
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
