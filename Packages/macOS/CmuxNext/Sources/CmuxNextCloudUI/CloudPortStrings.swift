import Foundation

/// The machine and port a Cloud port message names: the machine's name for the reader, its id
/// for the next command (`--target machine:<id>`), and the port (`<port>` when none was given).
public struct CloudPortNames: Equatable {
    public var name: String
    public var id: String
    public var port: String

    public init(name: String, id: String, port: Int?) {
        self.name = name
        self.id = id
        self.port = port.map(String.init) ?? "<port>"
    }
}

/// What `cmux cloud open-browser`, `port-list`, `port-forward`, `port-close` and `machine-link`
/// say (CloudHandlers+Browser.swift). Each failure names the machine and the port and gives the
/// next command. Keys live in Resources/CloudPorts.xcstrings with every app locale.
public struct CloudPortStrings {
    public init() {}
    /// A machine on the classic link (`/api/vm` and `cmux-tui remote connect`): the Cloud app
    /// server keeps no forward for it.
    public static func classicLink(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.classicLink",
                              defaultValue: "Machine `%1$@` uses the classic Cloud link, which keeps no port forwards on this Mac. Run `cmux cloud open-browser --target machine:%2$@ --port %3$@` to open the port in a browser tab, or `cmux cloud machine-link --target machine:%2$@ --port %3$@` for its URL.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// `port-close` of a port that has no forward.
    public static func noForward(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.noForward",
                              defaultValue: "Machine `%1$@` has no forward of port %3$@. `cmux cloud port-list --target machine:%2$@` lists its forwards.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// The Cloud app server's `cmux.cloud.port_limit`: close one of the open forwards (`<port>` from the list).
    public static func limit(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.limit",
                              defaultValue: "Couldn't forward port %3$@ of machine `%1$@`: this Mac already has the most port forwards and browser routes open. `cmux cloud port-list --target machine:%2$@` lists them, and `cmux cloud port-close --target machine:%2$@ --port <port>` closes one.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// Any other refusal of a port op; `detail` is the server's own message.
    public static func failed(_ names: CloudPortNames, detail: String) -> String {
        String(format: String(localized: "cloud.ports.failed",
                              defaultValue: "Couldn't reach port %3$@ on machine `%1$@`: %4$@. Check the machine with `cmux cloud machine-status --target machine:%2$@`, then run the command again.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port, detail)
    }

    /// The browser tab could not open; `detail` says why (Chromium's own reason, or a route code).
    public static func browserFailed(_ names: CloudPortNames, detail: String) -> String {
        String(format: String(localized: "cloud.ports.browserFailed",
                              defaultValue: "Couldn't open port %3$@ of machine `%1$@` in a browser tab: %4$@. Fix that, then run `cmux cloud open-browser --target machine:%2$@ --port %3$@` again.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port, detail)
    }

    public static func noWindow(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.noWindow",
                              defaultValue: "No cmux window is open to show port %3$@ of machine `%1$@`. Run `cmux app new-window`, then `cmux cloud open-browser --target machine:%2$@ --port %3$@` again.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    public static func updateMachine(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.updateMachine",
                              defaultValue: "Machine `%1$@` can't show its port %3$@ in a browser tab: its cmux is too old. Run `cmux cloud machine-link --target machine:%2$@ --port %3$@` for a link to the port, or start a newer machine with `cmux cloud new-machine`.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// `browser.remoteLocalhost` is off for the machine's workspace.
    public static func localhostOff(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.localhostOff",
                              defaultValue: "Machine `%1$@` has browser.remoteLocalhost turned off for its workspace, so a browser tab would show this Mac's port %3$@ instead. Turn it on in cmux.json, then run `cmux cloud open-browser --target machine:%2$@ --port %3$@` again.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// A machine whose provider opens no port link (`machine-link --port` on the classic link).
    public static func noLink(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.noLink",
                              defaultValue: "Machine `%1$@` can't make a link to port %3$@: its provider opens no port links. Run `cmux cloud open-browser --target machine:%2$@ --port %3$@` instead.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// The app could not use the machine's browser route; `code` follows as a trace.
    public static func routeRefused(_ code: String) -> String {
        String(format: String(localized: "cloud.ports.routeRefused", defaultValue: "the machine's browser route could not be used (%@)",
                              table: "CloudPorts", bundle: .module), code)
    }

    /// `open-browser --path` that is no path.
    public static func pathInvalid(_ names: CloudPortNames) -> String {
        String(format: String(localized: "cloud.ports.pathInvalid",
                              defaultValue: "Machine `%1$@` can't open that path on port %3$@: pass one that starts with / and has no spaces, for example `cmux cloud open-browser --target machine:%2$@ --port %3$@ --path /docs`.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, names.port)
    }

    /// A `--port` outside 1...65535; `verb` is the command after `cmux cloud` (`open-browser`).
    public static func invalidPort(_ names: CloudPortNames, verb: String) -> String {
        String(format: String(localized: "cloud.ports.invalidPort",
                              defaultValue: "Pass a port from 1 to 65535 for machine `%1$@`, for example `cmux cloud %3$@ --target machine:%2$@ --port 3000`.",
                              table: "CloudPorts", bundle: .module), names.name, names.id, verb)
    }

    /// The sheet title of a person's port list, forward or link.
    public static var title: String {
        String(localized: "cloud.ports.title", defaultValue: "Machine Ports", table: "CloudPorts", bundle: .module)
    }

    public static var none: String {
        String(localized: "cloud.ports.none", defaultValue: "No port of this machine is forwarded to this Mac.", table: "CloudPorts", bundle: .module)
    }

    public static var openPreview: String {
        String(localized: "cloud.ports.openPreview", defaultValue: "Open in Browser", table: "CloudPorts", bundle: .module)
    }

    public static var noPreviews: String {
        String(localized: "cloud.ports.noPreviews", defaultValue: "No live previews are available yet. Try again when the machine's web server is ready.", table: "CloudPorts", bundle: .module)
    }
}
