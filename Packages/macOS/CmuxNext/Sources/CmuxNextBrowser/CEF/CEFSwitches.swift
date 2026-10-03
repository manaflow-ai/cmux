import Foundation

/// Browser-process command-line switches for the embedded Chromium.
nonisolated struct CEFSwitches: Equatable, Sendable {
    /// `cmux_cef_api_version()`; 0 for stock CEF.
    var forkAPIVersion: Int32
    /// Development builds share one ad hoc identity per tag; the real
    /// keychain would prompt for "Chromium Safe Storage" on every rebuild.
    var useMockKeychain: Bool
    /// Unpacked extension directories (development and verification only).
    var loadExtensions: [String]
    /// Extra Chromium switches for diagnosis (development bundles only), for
    /// example `show-browser-frame-regions` or `enable-ui-devtools=9223`.
    var extraSwitches: [String] = []

    var arguments: [String] {
        var result: [String] = []
        if forkAPIVersion >= 1 {
            // One Chromium Browser per pane host, Chromium's own UI hidden
            // (include/cef_cmux.h in the fork).
            result.append("cmux-tabbed-windows")
        }
        // Non-official builds otherwise enable the field trial testing config
        // (features that need helpers cmux does not ship).
        result.append("disable-field-trial-config")
        // Web notifications must not make CEF's Alerts helper request a
        // separate macOS notification authorization. DesktopNotifier owns the
        // one app-level authorization request when cmux posts a banner.
        result.append("disable-notifications")
        if useMockKeychain {
            result.append("use-mock-keychain")
        }
        if !loadExtensions.isEmpty {
            result.append("load-extension=" + loadExtensions.joined(separator: ","))
        }
        result.append(contentsOf: extraSwitches)
        return result
    }

    /// Switches for this process. `CMUX_NEXT_CEF_LOAD_EXTENSIONS` is a
    /// colon-separated list of unpacked extension directories.
    /// `CMUX_NEXT_CEF_EXTRA_SWITCHES` is a colon-separated list of switches
    /// (leading dashes optional). Debug builds of development bundles only;
    /// see plans/cmux-next/browser.md ("Chromium diagnostics").
    static func current(
        forkAPIVersion: Int32,
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> CEFSwitches {
        let bundle = bundleIdentifier ?? ""
        let dev = bundle.contains(".debug") || bundle.hasSuffix(".dev") || environment["CMUX_MOCK_KEYCHAIN"] == "1"
        let extensions = (environment["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        #if DEBUG
        let extra = dev ? Self.extraSwitches(environment["CMUX_NEXT_CEF_EXTRA_SWITCHES"]) : []
        #else
        let extra: [String] = []
        #endif
        return CEFSwitches(
            forkAPIVersion: forkAPIVersion,
            useMockKeychain: dev,
            loadExtensions: extensions,
            extraSwitches: extra
        )
    }

    static func extraSwitches(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ":")
            .map { String($0.drop { $0 == "-" }) }
            .filter { !$0.isEmpty }
    }
}
