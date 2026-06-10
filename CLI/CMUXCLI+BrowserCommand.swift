import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Browser command
extension CMUXCLI {
    /// Thin dispatcher: parses the shared browser-command prologue into a
    /// `BrowserCommandContext`, then tries each per-family subcommand handler.
    /// Every handler matches subcommands by exact string equality on disjoint
    /// sets, so the family order cannot change which handler runs.
    func runBrowserCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !commandArgs.isEmpty else {
            throw CLIError(message: "browser requires a subcommand")
        }

        var effectiveJSONOutput = jsonOutput
        var effectiveIDFormat = idFormat
        var browserArgs = commandArgs

        // Browser-skill examples often place output flags at the end of the command.
        // Strip trailing display flags so they don't become part of a URL or selector.
        while !browserArgs.isEmpty {
            if browserArgs.last == "--json" {
                effectiveJSONOutput = true
                browserArgs.removeLast()
                continue
            }

            if browserArgs.count >= 2,
               browserArgs[browserArgs.count - 2] == "--id-format" {
                let raw = browserArgs.last!
                guard let parsed = try CLIIDFormat.parse(raw) else {
                    throw CLIError(message: "--id-format must be one of: refs, uuids, both")
                }
                effectiveIDFormat = parsed
                browserArgs.removeLast(2)
                continue
            }

            break
        }

        let (surfaceOpt, argsWithoutSurfaceFlag) = parseOption(browserArgs, name: "--surface")
        var surfaceRaw = surfaceOpt
        var args = argsWithoutSurfaceFlag

        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify", "import", "profile", "profiles"]
        if surfaceRaw == nil, let first = args.first {
            if !first.hasPrefix("-") && !verbsWithoutSurface.contains(first.lowercased()) {
                surfaceRaw = first
                args = Array(args.dropFirst())
            }
        }

        guard let subcommandRaw = args.first else {
            throw CLIError(message: "browser requires a subcommand")
        }
        let subcommand = subcommandRaw.lowercased()
        let subArgs = Array(args.dropFirst())

        let ctx = BrowserCommandContext(
            cli: self,
            client: client,
            subcommand: subcommand,
            subArgs: subArgs,
            surfaceRaw: surfaceRaw,
            effectiveJSONOutput: effectiveJSONOutput,
            effectiveIDFormat: effectiveIDFormat
        )

        if try runBrowserDiagnosticsSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserProfileSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserNavigationSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserInspectionSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserInteractionSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserCaptureSubcommands(ctx, subcommand: subcommand) {
            return
        }
        if try runBrowserStateSubcommands(ctx, subcommand: subcommand) {
            return
        }

        throw CLIError(message: "Unsupported browser subcommand: \(subcommand)")
    }
}
