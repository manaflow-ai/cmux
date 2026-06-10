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


// MARK: - Browser availability and presentation options
extension CMUXCLI {
    private static let browserDisabledDefaultsKey = "browserDisabledOverride"
    private static let defaultBrowserSettingsDomain = "com.cmuxterm.app"

    private static func containingAppBundleIdentifier() -> String? {
        normalizedEnvValue(CLIExecutableLocator.enclosingAppBundle()?.bundleIdentifier)
    }

    private static func browserSettingsDomain(environment: [String: String]) -> String {
        normalizedEnvValue(environment["CMUX_BUNDLE_ID"])
        ?? containingAppBundleIdentifier()
        ?? defaultBrowserSettingsDomain
    }

    // Presentation flags are global, but command option values can also look like flags.
    private static let commandOptionsWithValues: Set<String> = [
        "--action", "--after-workspace", "--agent", "--amount", "--arch",
        "--attr", "--before-workspace", "--body", "--color", "--command",
        "--config", "--cwd", "--description", "--direction", "--domain",
        "--dx", "--dy", "--email", "--event", "--expires", "--focus",
        "--function", "--id", "--image", "--index", "--key", "--kind",
        "--layout", "--lines", "--load-state", "--max-depth", "--name", "--os",
        "--order", "--out", "--pane", "--panel", "--path", "--profile", "--property",
        "--provider", "--relay-port", "--script", "--selector", "--session",
        "--shell", "--source", "--subtitle", "--surface", "--tab", "--target-pane",
        "--text", "--timeout", "--timeout-ms", "--title", "--transcript",
        "--turn", "--type", "--url", "--url-contains", "--value", "--window",
        "--workspace", "--checkpoint", "--checkpoint-id",
    ]

    func parsePresentationOptions(
        _ commandArgs: [String]
    ) throws -> (jsonOutput: Bool, idFormat: String?, remaining: [String]) {
        var jsonOutput = false
        var idFormat: String?
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if pastTerminator {
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormat = commandArgs[index + 1]
                index += 2
                continue
            }
            remaining.append(arg)
            if Self.commandOptionsWithValues.contains(arg), index + 1 < commandArgs.count {
                remaining.append(commandArgs[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return (jsonOutput, idFormat, remaining)
    }

    func runBrowserAvailabilityCommand(
        command: String,
        commandArgs: [String],
        jsonOutput globalJSONOutput: Bool,
        environment: [String: String]
    ) throws {
        var effectiveJSONOutput = globalJSONOutput
        var args = commandArgs
        if let jsonIndex = args.firstIndex(of: "--json") {
            effectiveJSONOutput = true
            args.remove(at: jsonIndex)
        }

        let action: String
        if command == "browser" {
            guard let first = args.first?.lowercased() else {
                throw CLIError(message: "browser requires a subcommand")
            }
            action = first
            args = Array(args.dropFirst())
        } else {
            action = command
        }

        guard args.isEmpty else {
            throw CLIError(message: "Unexpected argument: \(args[0])")
        }

        let domain = Self.browserSettingsDomain(environment: environment)
        let defaults = UserDefaults(suiteName: domain) ?? .standard

        switch action {
        case "disable", "disable-browser":
            defaults.set(true, forKey: Self.browserDisabledDefaultsKey)
            defaults.synchronize()
        case "enable", "enable-browser":
            defaults.set(false, forKey: Self.browserDisabledDefaultsKey)
            defaults.synchronize()
        case "status", "browser-status":
            break
        default:
            throw CLIError(message: "Unknown browser availability command: \(action)")
        }

        let disabled = defaults.object(forKey: Self.browserDisabledDefaultsKey) == nil
            ? false
            : defaults.bool(forKey: Self.browserDisabledDefaultsKey)
        let payload: [String: Any] = [
            "enabled": !disabled,
            "disabled": disabled,
            "domain": domain,
            "key": Self.browserDisabledDefaultsKey
        ]
        if effectiveJSONOutput {
            print(jsonString(payload))
        } else if action == "status" || action == "browser-status" {
            print(disabled ? "disabled" : "enabled")
        } else {
            print(disabled ? "cmux browser disabled" : "cmux browser enabled")
        }
    }

    static func shouldFocusWindowBeforeDispatch(command: String, commandArgs: [String]) -> Bool {
        let normalizedCommand = command.lowercased()
        if normalizedCommand == "surface-resume" {
            return false
        }
        if normalizedCommand == "surface", commandArgs.first?.lowercased() == "resume" {
            return false
        }
        return true
    }

}
