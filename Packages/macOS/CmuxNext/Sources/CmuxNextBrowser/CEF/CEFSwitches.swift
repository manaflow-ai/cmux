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
            // One Chromium Browser per pane host, Chrome UI hidden
            // (include/cef_cmux.h in the fork).
            result.append("cmux-tabbed-windows")
        }
        // Non-official builds otherwise enable the field trial testing config
        // (features that need helpers cmux does not ship).
        result.append("disable-field-trial-config")
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
    /// without leading dashes, read only by development bundles.
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
        let extra = dev
            ? (environment["CMUX_NEXT_CEF_EXTRA_SWITCHES"] ?? "")
                .split(separator: ":")
                .map { String($0.drop { $0 == "-" }) }
                .filter { !$0.isEmpty }
            : []
        return CEFSwitches(
            forkAPIVersion: forkAPIVersion,
            useMockKeychain: dev,
            loadExtensions: extensions,
            extraSwitches: extra
        )
    }
}
