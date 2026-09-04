import Foundation

/// Builds a safe, deterministic command line for a managed Chromium child.
///
/// The builder owns all security-sensitive switches. In particular, callers
/// cannot replace the profile directory or bind CDP to a non-loopback address.
struct ChromiumLaunchArguments: Equatable, Sendable {
    static let loopbackAddress = "127.0.0.1"
    let values: [String]

    init(configuration: ChromiumLaunchConfiguration) {
        let width = max(1, min(configuration.viewportWidth, 16_384))
        let height = max(1, min(configuration.viewportHeight, 16_384))
        var arguments = [
            "--headless=new",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            "--window-size=\(width),\(height)",
            "--user-data-dir=\(configuration.profileDirectory.standardizedFileURL.path)",
        ]

        switch configuration.debuggingTransport {
        case .pipe:
            arguments.append("--remote-debugging-pipe")
        case .loopback(let requestedPort):
            let port = max(1, min(requestedPort, 65_535))
            arguments.append("--remote-debugging-address=\(Self.loopbackAddress)")
            arguments.append("--remote-debugging-port=\(port)")
            // Chromium rejects websocket clients that carry an Origin unless
            // that origin is explicitly allow-listed. Keep the list exact to
            // this loopback port; never use `*`, which would turn a local CDP
            // listener into a browser-control endpoint for arbitrary pages.
            arguments.append(
                "--remote-allow-origins=http://127.0.0.1:\(port),http://localhost:\(port),devtools://devtools"
            )
        }

        // Do not allow an override to smuggle in a second profile or a public
        // debugging listener. Chromium accepts both `--flag=value` and
        // `--flag value`; consume the value in the latter form as well.
        let forbiddenValueFlags = [
            "--user-data-dir",
            "--remote-debugging-address",
            "--remote-debugging-port",
            "--remote-allow-origins",
        ]
        let forbiddenSwitches = ["--remote-debugging-pipe"]
        var skipNextArgument = false
        for argument in configuration.additionalArguments {
            if skipNextArgument {
                skipNextArgument = false
                continue
            }
            let normalized = argument.lowercased()
            if forbiddenSwitches.contains(normalized) {
                continue
            }
            if forbiddenValueFlags.contains(normalized) {
                skipNextArgument = true
                continue
            }
            if forbiddenValueFlags.contains(where: { normalized.hasPrefix("\($0)=") }) ||
                forbiddenSwitches.contains(where: { normalized.hasPrefix("\($0)=") }) {
                continue
            }
            arguments.append(argument)
        }
        // A page target is required for page-scoped CDP. Supplying an explicit
        // blank document gives panes created without a URL the same target
        // lifetime as panes that navigate immediately.
        arguments.append("about:blank")
        values = arguments
    }
}
