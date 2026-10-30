public import CmuxNextDesign

/// Debug Settings of the Chromium host app prototype (DEV and NIGHTLY;
/// Release and RC never activate the store; the host app ships in Debug
/// builds only). plans/cmux-next/cef-helper-app-DESIGN.md.
public nonisolated struct BrowserHostTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserHost", title: "Chromium Host App", symbol: "macwindow.on.rectangle", order: 44)

    /// Off (the default): `debug.chromium_host open` refuses. On: it shows a
    /// Chromium page whose browser process runs in the Chromium host app, over
    /// a pane, through the window's own layers.
    public static let helperPrototype = Tunable<Bool>.toggle(
        "browserHost.helperPrototype", section, "Chromium host app prototype",
        help: "Lets debug.chromium_host show a Chromium page whose browser process runs in its own app, so a Chromium crash ends only that app. Debug builds only.",
        default: false, code: "BrowserHostTunables.helperPrototype")

    public static var all: [TunableDescriptor] { [helperPrototype.descriptor] }
}
