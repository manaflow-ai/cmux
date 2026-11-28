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
    /// `resources` is the app bundle's `Contents/Resources`. Off the main actor: it resolves acpmux,
    /// whose signature check reads the whole executable (``ownerEnvironment(home:process:resources:)``).
    nonisolated static func brainsValue(home: ChiefHome, process: [String: String], resources: URL?) -> String? {
        let bin = resources?.appendingPathComponent("bin", isDirectory: true)
        guard let host = HomeBrainHost.resolve(daemonSocket: "", controlSocket: "", home: home, environment: process,
                                               bundledBinDirectory: bin) else {
            return nil
        }
        struct Request: Encodable {
            let executable, home, userName, chiefTitle: String
            let binDir, path, acpmuxBin, bundledCli, harness: String?
        }
        struct Reply: Decodable { let value: String }
        // The person's login PATH: a claude outside the fixed tool
        // directories (Homebrew elsewhere, nvm) is found by the brain and
        // its acpmux too.
        let request = Request(executable: host.executable.path, home: home.muxHome.path,
                              userName: HomeChiefName.localUserName, chiefTitle: HomeStrings.chiefName,
                              binDir: bin?.path, path: LoginEnvironment.shared.rememberedPath(),
                              acpmuxBin: host.acpmux?.executable.path,
                              bundledCli: host.acpmux?.childEnvironment["CMUX_BUNDLED_CLI_PATH"],
                              harness: process["MUX_HARNESS"])
        let reply: Reply? = try? ChiefHomeRules().call("owner_brains_value", request)
        return reply?.value
    }
}
