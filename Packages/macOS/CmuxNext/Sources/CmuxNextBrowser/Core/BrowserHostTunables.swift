public import CmuxNextCompat
public import CmuxNextDesign
import Foundation

/// Debug Settings of the Chromium host app (DEV and NIGHTLY; Release and RC
/// never activate the store, so they keep the default). The host app ships in
/// Debug builds only. plans/cmux-next/cef-helper-app-DESIGN.md.
public nonisolated struct BrowserHostTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserHost", title: "Chromium Host App", symbol: "macwindow.on.rectangle", order: 44)

    /// Host mode: Chromium's browser process runs in the Chromium host app, so
    /// a Chromium crash ends only that app. The default is this build's
    /// channel default (``helperDefault(for:)``): on in DEV only until task
    /// p01-process-104 (plans/cmux-next/chrome-parity/p01-process.md).
    public static let helper = declaration(for: BuildIdentity(bundle: .main).kind)

    /// The `browserHost.helper` declaration with the channel default of `kind`.
    public static func declaration(for kind: BuildIdentity.Kind) -> Tunable<Bool> {
        Tunable<Bool>.toggle(
            "browserHost.helper", section, "Chromium host app",
            help: "Runs Chromium's browser process in its own app, so a Chromium crash ends only that app. On by default in DEV builds only.",
            default: helperDefault(for: kind), code: "BrowserHostTunables.helper")
    }

    /// The channel default of `browserHost.helper`, by the channel mapping of
    /// `Feature.Channel` (Chromium's per-channel feature defaults): DEV, and
    /// staging and unbundled processes, which take the DEV defaults, on;
    /// NIGHTLY, RC and Release off.
    public static func helperDefault(for kind: BuildIdentity.Kind) -> Bool {
        switch kind {
        case .dev, .staging, .unbundled: true
        case .nightly, .release, .rc: false
        }
    }

    public static var all: [TunableDescriptor] { [helper.descriptor] }
}
