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
    /// (Debug builds only), otherwise ``BrowserBackend/inProcess``.
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

    /// Off (the default until task 100): Chromium runs in process and
    /// `debug.chromium_host open` refuses. On: Chromium's browser process runs
    /// in the Chromium Host app (``BrowserBackend/host``), and
    /// `debug.chromium_host` shows a page of it over a pane.
    public static let helper = Tunable<Bool>.toggle(
        "browserHost.helper", section, "Chromium in its own app",
        help: "Runs Chromium's browser process in the Chromium Host app, so a Chromium crash ends only that app. Debug builds only.",
        default: false, code: "BrowserHostTunables.helper")
    #endif
}
