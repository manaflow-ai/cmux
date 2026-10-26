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

/// Debug Settings of the Chromium Host app: Debug builds only, like the host
/// app itself (embed-cef.sh) and its Swift side, so a NIGHTLY never lists a
/// toggle for a host it does not bundle.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
public nonisolated struct BrowserHostTunables {
    public nonisolated init() {}

    /// The tunables to register: none outside Debug builds.
    public static var all: [TunableDescriptor] {
        #if DEBUG
        [helper.descriptor]
        #else
        []
        #endif
    }

    /// The backend the settings pick: ``BrowserBackend/host`` with `browserHost.helper` on
    /// (Debug builds only), otherwise ``BrowserBackend/inProcess``. The App builds its
    /// `CEFRuntimeSource` from it once the supervisor exists (task 080); until then no tab uses it.
    public static func backend(in tunables: TunableStore) -> BrowserBackend {
        #if DEBUG
        helper.value(in: tunables) ? .host : .inProcess
        #else
        .inProcess
        #endif
    }

    #if DEBUG
    /// The Debug Settings section of the host app's tunables.
    public static let section = TunableSection(id: "browserHost", title: "Chromium Host App", symbol: "macwindow.on.rectangle", order: 44)

    /// Off (the default until task 100): `debug.chromium_host open` refuses.
    /// On: it shows a Chromium page whose browser process runs in the Chromium
    /// Host app, over a pane. Tabs stay in process until the supervisor (task
    /// 080) hands ``backend(in:)`` to the runtime.
    public static let helper = Tunable<Bool>.toggle(
        "browserHost.helper", section, "Chromium Host app",
        help: "Lets debug.chromium_host show a Chromium page whose browser process runs in the Chromium Host app. Chromium tabs still run in cmux until the host supervisor lands. Debug builds only.",
        default: false, code: "BrowserHostTunables.helper")
    #endif
}
