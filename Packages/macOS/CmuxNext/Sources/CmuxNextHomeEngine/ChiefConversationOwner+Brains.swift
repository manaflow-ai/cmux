import CmuxNextDaemon
import Foundation

extension ChiefConversationOwner {
    /// `CMUX_TUI_CHIEF_BRAINS` for this home's owner daemon (Multi-Chief S6,
    /// cmux-tui-core chief_brains.rs): the daemon starts the brain of each
    /// Chief that is not the default, in `<home>/chiefs/<id>`, and builds
    /// its environment itself. The app gives only what the daemon cannot
    /// know: the brain executable (the same rule as Home's, so Release and
    /// RC give none and start no brain), this home, its bundle `bin`, the
    /// person's name, its login PATH, the localized Chief title, the bundled CLI and acpmux,
    /// and the harness of its own environment (no MCP command: acpmux gives
    /// each agent chat its own cmux MCP server). The default
    /// Chief's brain stays with Home (ChiefBrainKeeper), unchanged.
    static func brainsValue(home: ChiefHome, process: [String: String], bundle: Bundle) -> String? {
        let bin = bundle.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let host = HomeBrainHost.resolve(daemonSocket: "", controlSocket: "", home: home, environment: process,
                                               bundledBinDirectory: bin) else {
            return nil
        }
        var app: [String: String] = [
            "user_name": HomeChiefName.localUserName,
            "chief_title": HomeStrings.chiefName,
        ]
        if let bin { app["bin_dir"] = bin.path }
        // The person's login PATH: a claude outside the fixed tool
        // directories (Homebrew elsewhere, nvm) is found by the brain and
        // its acpmux too.
        if let path = LoginEnvironment.shared.rememberedPath(), !path.isEmpty { app["path"] = path }
        if let acpmux = host.acpmux {
            app["acpmux_bin"] = acpmux.executable.path
            if let cli = acpmux.childEnvironment["CMUX_BUNDLED_CLI_PATH"] { app["bundled_cli"] = cli }
        }
        if let harness = process["MUX_HARNESS"], !harness.isEmpty { app["harness"] = harness }
        // Once this app exits, an idle brain stops (optchat-chief owner_app.rs).
        let value: [String: Any] = ["executable": host.executable.path, "home": home.muxHome.path, "app": app]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
