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

// MARK: - Browser profile and import subcommands
extension CMUXCLI {
    /// Handles profile/profiles and import.
    /// Returns true when the subcommand was handled.
    func runBrowserProfileSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if subcommand == "profile" || subcommand == "profiles" {
            let profileVerb = ctx.subArgs.first?.lowercased() ?? "list"
            let profileArgs = ctx.subArgs.first != nil ? Array(ctx.subArgs.dropFirst()) : []
            let normalizedVerb: String
            switch profileVerb {
            case "ls":
                normalizedVerb = "list"
            case "add", "new":
                normalizedVerb = "create"
            case "remove", "rm":
                normalizedVerb = "delete"
            default:
                normalizedVerb = profileVerb
            }

            switch normalizedVerb {
            case "list":
                let payload = try ctx.client.sendV2(method: "browser.profiles.list")
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                } else {
                    ctx.printBrowserProfiles(payload)
                }
            case "create":
                let (nameOpt, remaining) = parseOption(profileArgs, name: "--name")
                let name = nameOpt ?? ctx.nonFlagArgs(remaining).joined(separator: " ")
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a name")
                }
                let payload = try ctx.client.sendV2(method: "browser.profiles.create", params: ["name": name])
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                } else if let profileDict = payload["profile"] as? [String: Any],
                          let profile = ctx.browserProfileLine(profileDict) {
                    print("Created browser profile \(profile)")
                } else {
                    print("Created browser profile")
                }
            case "rename":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let (nameOpt, rem2) = parseOption(rem1, name: "--name")
                let positional = ctx.nonFlagArgs(rem2)
                let profile = profileOpt ?? positional.first
                let newName = nameOpt ?? (positional.count > 1 ? positional.dropFirst().joined(separator: " ") : nil)
                guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile")
                }
                guard let newName, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a new name")
                }
                let payload = try ctx.client.sendV2(
                    method: "browser.profiles.rename",
                    params: ["profile": profile, "new_name": newName]
                )
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                } else if let renamed = ctx.stringPayloadValue((payload["profile"] as? [String: Any])?["name"]) {
                    print("Renamed browser profile to \(renamed).")
                } else {
                    print("Renamed browser profile.")
                }
            case "clear":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let positional = ctx.nonFlagArgs(rem1)
                var params: [String: Any] = [:]
                if hasFlag(profileArgs, name: "--all") {
                    params["all"] = true
                } else if let profile = profileOpt ?? positional.first {
                    params["profile"] = profile
                } else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile or --all")
                }
                if hasFlag(profileArgs, name: "--force") {
                    params["force"] = true
                }
                let payload = try ctx.client.sendV2(method: "browser.profiles.clear", params: params, responseTimeout: 120)
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                } else {
                    let count = ctx.intPayloadValue(payload["count"])
                    print("Cleared \(count) browser profile\(count == 1 ? "" : "s").")
                }
            case "delete":
                let (profileOpt, rem1) = parseOption(profileArgs, name: "--profile")
                let profile = profileOpt ?? ctx.nonFlagArgs(rem1).first
                guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "browser profiles \(profileVerb) requires a profile")
                }
                let payload = try ctx.client.sendV2(
                    method: "browser.profiles.delete",
                    params: ["profile": profile],
                    responseTimeout: 120
                )
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                } else if let deleted = ctx.stringPayloadValue((payload["profile"] as? [String: Any])?["name"]) {
                    print("Deleted browser profile \(deleted).")
                } else {
                    print("Deleted browser profile.")
                }
            default:
                throw CLIError(message: "Unsupported browser profiles subcommand: \(profileVerb)")
            }
            return true
        }

        if subcommand == "import" {
            let importArgs = ctx.subArgs
            let importValueOptions: Set<String> = [
                "--from",
                "--browser",
                "--source",
                "--profile",
                "--source-profile",
                "--to",
                "--to-profile",
                "--destination-profile",
                "--domain",
                "--domains",
            ]
            let importFlags: Set<String> = [
                "--interactive",
                "--non-interactive",
                "--noninteractive",
                "--yes",
                "-y",
                "--all-profiles",
                "--create-profile",
                "--create-destination-profile",
            ]
            func importPositionals(_ values: [String]) -> [String] {
                var result: [String] = []
                var index = 0
                var pastTerminator = false
                while index < values.count {
                    let value = values[index]
                    if pastTerminator {
                        result.append(value)
                        index += 1
                        continue
                    }
                    if value == "--" {
                        pastTerminator = true
                        index += 1
                        continue
                    }
                    if importValueOptions.contains(value) {
                        index += index + 1 < values.count ? 2 : 1
                        continue
                    }
                    if importFlags.contains(value) || value.hasPrefix("-") {
                        index += 1
                        continue
                    }
                    result.append(value)
                    index += 1
                }
                return result
            }
            let unsupportedPositionals = importPositionals(importArgs)
            if let first = unsupportedPositionals.first {
                let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized == "cookie" || normalized == "cookies" {
                    throw CLIError(message: "browser import no longer takes a data type; use 'cmux browser import'")
                }
                throw CLIError(message: "browser import does not accept positional arguments")
            }
            let forceInteractive = hasFlag(importArgs, name: "--interactive")
            let forceNonInteractive = hasFlag(importArgs, name: "--non-interactive") ||
                hasFlag(importArgs, name: "--noninteractive") ||
                hasFlag(importArgs, name: "--yes") ||
                hasFlag(importArgs, name: "-y")
            if forceInteractive && forceNonInteractive {
                throw CLIError(message: "browser import cannot use both --interactive and --non-interactive")
            }

            let shouldRunNonInteractive = forceNonInteractive ||
                (!forceInteractive && Self.isCodingAgentEnvironment(ProcessInfo.processInfo.environment))

            var params: [String: Any] = shouldRunNonInteractive ? ["scope": "cookiesOnly"] : [:]
            if let browser = try ctx.firstOptionValue(importArgs, names: ["--from", "--browser", "--source"]) {
                params["browser"] = browser
            }
            let sourceProfiles = try ctx.optionValues(importArgs, names: ["--profile", "--source-profile"])
            if !sourceProfiles.isEmpty {
                params["source_profiles"] = sourceProfiles
            }
            if let destination = try ctx.firstOptionValue(importArgs, names: ["--to", "--to-profile", "--destination-profile"]) {
                params["destination_profile"] = destination
            }
            let domainFilters = try ctx.optionValues(importArgs, names: ["--domain", "--domains"])
            if !domainFilters.isEmpty {
                params["domain_filters"] = domainFilters
            }
            if hasFlag(importArgs, name: "--all-profiles") {
                params["all_profiles"] = true
            }
            if hasFlag(importArgs, name: "--create-profile") ||
                hasFlag(importArgs, name: "--create-destination-profile") {
                params["create_destination_profile"] = true
            }

            if shouldRunNonInteractive {
                let payload = try ctx.client.sendV2(
                    method: "browser.import.cookies",
                    params: params,
                    responseTimeout: 10 * 60
                )
                if ctx.effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
                    return true
                }

                let browserName = (payload["browser"] as? String) ?? "browser"
                let importedCount = ctx.intPayloadValue(payload["imported_cookies"])
                let skippedCount = ctx.intPayloadValue(payload["skipped_cookies"])
                print("Imported \(importedCount) cookies from \(browserName).")
                if skippedCount > 0 {
                    print("Skipped \(skippedCount) cookies.")
                }
                if let warnings = payload["warnings"] as? [String], !warnings.isEmpty {
                    for warning in warnings {
                        print("Warning: \(warning)")
                    }
                }
            } else {
                let payload = try ctx.client.sendV2(method: "browser.import.dialog", params: params, responseTimeout: 10 * 60)
                ctx.output(payload, fallback: "OK")
            }
            return true
        }

        return false
    }
}
