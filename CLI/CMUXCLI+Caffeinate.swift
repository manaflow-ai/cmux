import Foundation

extension CMUXCLI {
    /// `cmux caffeinate [status|on|off|toggle] [--lock-screen|--no-lock-screen]`
    ///
    /// Thin client over the app's `caffeine.status`/`caffeine.set` socket
    /// commands, which are the single caffeinate action path shared with the
    /// iOS Keep Awake RPC, the menu-bar toggle, and Settings.
    func runCaffeinateCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var lockScreen: Bool?
        var lockMac: Bool?
        var jsonFlag = false
        var positional: [String] = []
        for arg in commandArgs {
            switch arg {
            case "--lock-screen":
                lockScreen = true
            case "--no-lock-screen":
                lockScreen = false
            case "--lock-mac":
                lockMac = true
            case "--json":
                jsonFlag = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIError(message: String(
                        localized: "cli.caffeinate.error.unknownFlag",
                        defaultValue: "caffeinate: unknown flag '\(arg)'. Flags: --lock-screen, --no-lock-screen, --lock-mac, --json"
                    ))
                }
                positional.append(arg)
            }
        }
        guard positional.count <= 1 else {
            throw CLIError(message: String(
                localized: "cli.caffeinate.error.tooManyArguments",
                defaultValue: "caffeinate takes one subcommand: status, on, off, or toggle"
            ))
        }
        let subcommand = positional.first ?? "status"

        let payload: [String: Any]
        switch subcommand {
        case "status":
            guard lockScreen == nil, lockMac == nil else {
                throw CLIError(message: String(
                    localized: "cli.caffeinate.error.statusLockScreen",
                    defaultValue: "caffeinate status doesn't take lock-screen/lock-mac flags"
                ))
            }
            payload = try client.sendV2(method: "caffeine.status", params: [:])
        case "on", "off":
            payload = try setCaffeine(enabled: subcommand == "on", lockScreen: lockScreen, lockMac: lockMac, client: client)
        case "toggle":
            let status = try client.sendV2(method: "caffeine.status", params: [:])
            let enabled = (status["enabled"] as? Bool) ?? false
            payload = try setCaffeine(enabled: !enabled, lockScreen: lockScreen, lockMac: lockMac, client: client)
        default:
            throw CLIError(message: String(
                localized: "cli.caffeinate.error.unknownSubcommand",
                defaultValue: "Unknown caffeinate subcommand '\(subcommand)'. Use status, on, off, or toggle."
            ))
        }

        if jsonOutput || jsonFlag {
            print(jsonString(payload))
        } else {
            print(renderCaffeineStatusText(payload))
        }
    }

    private func setCaffeine(enabled: Bool, lockScreen: Bool?, lockMac: Bool?, client: SocketClient) throws -> [String: Any] {
        var params: [String: Any] = ["enabled": enabled]
        if let lockScreen {
            params["lock_screen"] = lockScreen
        }
        if let lockMac {
            params["lock_mac"] = lockMac
        }
        return try client.sendV2(method: "caffeine.set", params: params)
    }

    private func renderCaffeineStatusText(_ payload: [String: Any]) -> String {
        let enabled = (payload["enabled"] as? Bool) ?? false
        let lockScreenActive = (payload["lock_screen_active"] as? Bool) ?? false
        let awakeLine = enabled
            ? String(localized: "cli.caffeinate.status.on", defaultValue: "Keep Mac Awake: on")
            : String(localized: "cli.caffeinate.status.off", defaultValue: "Keep Mac Awake: off")
        let lockLine = lockScreenActive
            ? String(localized: "cli.caffeinate.lockScreen.shown", defaultValue: "Lock screen (Sleepy Mode): shown")
            : String(localized: "cli.caffeinate.lockScreen.hidden", defaultValue: "Lock screen (Sleepy Mode): hidden")
        return awakeLine + "\n" + lockLine
    }
}
