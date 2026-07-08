import Foundation

extension CMUXCLI {
    static let billingUsage = """
        Usage: cmux billing <status|checkout|portal> [options]

        Fetch live billing data from the app's configured web API origin
        (cmux.com in production) for the currently signed-in user. The CLI talks
        to the running cmux app over the control socket; the app makes the
        authenticated request with its Stack session.

          cmux billing status [--json]
              Print the live plan summary. --json prints the server JSON body.

          cmux billing checkout [--plan pro|team] [--url | --open]
              Start checkout for the signed-in user. Default: --plan pro --open.

          cmux billing portal [--url | --open]
              Open the Stripe customer portal for the signed-in user. Default: --open.
        """

    func runBillingCommand(commandArgs: [String], client: SocketClient, jsonOutput globalJSONOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "status"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.billingUsage)

        case "status":
            let jsonOutput = globalJSONOutput || rest.contains("--json")
            let remaining = rest.filter { $0 != "--json" }
            try rejectUnexpectedBillingArguments(remaining, command: "billing status")
            let response = try client.sendV2(method: "billing.status", responseTimeout: 75)
            try handleBillingStructuredError(response)
            let plan = (response["plan"] as? [String: Any]) ?? response
            if jsonOutput {
                print(jsonString(plan))
                return
            }
            printBillingStatus(plan, source: response["source"] as? String)

        case "checkout":
            let (planOpt, rem0) = parseOption(rest, name: "--plan")
            let mode = try billingURLMode(rem0, command: "billing checkout")
            let plan = (planOpt ?? "pro").lowercased()
            guard plan == "pro" || plan == "team" else {
                throw CLIError(message: "billing checkout: --plan must be pro or team.")
            }
            let response = try client.sendV2(
                method: "billing.checkout",
                params: ["plan": plan],
                responseTimeout: 75
            )
            try handleBillingURLResponse(response, mode: mode, noun: "checkout")

        case "portal":
            let mode = try billingURLMode(rest, command: "billing portal")
            let response = try client.sendV2(method: "billing.portal", responseTimeout: 75)
            try handleBillingURLResponse(response, mode: mode, noun: "portal")

        default:
            throw CLIError(message: """
                Unknown billing subcommand: \(sub)

                \(Self.billingUsage)
                """)
        }
    }

    private enum BillingURLMode {
        case open
        case url
    }

    private func billingURLMode(_ args: [String], command: String) throws -> BillingURLMode {
        var mode = BillingURLMode.open
        for arg in args {
            switch arg {
            case "--open":
                mode = .open
            case "--url":
                mode = .url
            default:
                throw CLIError(message: "\(command): unknown argument '\(arg)'.\n\n\(Self.billingUsage)")
            }
        }
        return mode
    }

    private func rejectUnexpectedBillingArguments(_ args: [String], command: String) throws {
        if let first = args.first {
            throw CLIError(message: "\(command): unknown argument '\(first)'.\n\n\(Self.billingUsage)")
        }
    }

    private func printBillingStatus(_ plan: [String: Any], source: String?) {
        let planId = billingString(plan["planId"]) ?? "free"
        let teamPlanId = billingString(plan["teamPlanId"]) ?? "free"
        let planName = billingDisplayPlanName(planId: planId, isPro: billingBool(plan["isPro"]))
        let isPro = billingBool(plan["isPro"]) ?? false
        let billingManagement = billingString(plan["billingManagement"]) ?? "none"
        let teamBillingManagement = billingString(plan["teamBillingManagement"]) ?? "none"
        let manualOverride = billingBool(plan["hasManualVmPlanOverride"]) ?? false
        let billingAvailable = billingBool(plan["billingAvailable"]) ?? true

        print("plan: \(planName)")
        print("pro active: \(isPro ? "yes" : "no")")
        print("team plan: \(billingDisplayPlanName(planId: teamPlanId, isPro: nil))")
        print("billing available: \(billingAvailable ? "yes" : "no")")
        print("billing management: \(billingManagement)")
        print("team billing management: \(teamBillingManagement)")
        print("manual VM override: \(manualOverride ? "yes" : "no")")
        if let source, !source.isEmpty {
            print("source: \(source)")
        }
    }

    private func handleBillingURLResponse(_ response: [String: Any], mode: BillingURLMode, noun: String) throws {
        try handleBillingStructuredError(response)
        guard let url = response["url"] as? String, !url.isEmpty else {
            let state = billingString(response["billing"])
                ?? billingString(response["welcome"])
                ?? billingString(response["error"])
                ?? "unavailable"
            let source = (response["source"] as? String).map { " (source: \($0))" } ?? ""
            throw CLIError(message: "Billing \(noun) is not available: \(state)\(source)")
        }
        switch mode {
        case .url:
            print(url)
        case .open:
            try openBillingURL(url)
            print("Opened billing \(noun): \(url)")
            if let source = response["source"] as? String, !source.isEmpty {
                print("source: \(source)")
            }
        }
    }

    private func handleBillingStructuredError(_ response: [String: Any]) throws {
        if let ok = response["ok"] as? Bool, ok == false {
            let error = billingString(response["error"]) ?? "billing_unavailable"
            let source = (response["source"] as? String).map { "source: \($0)" }
            let detail = billingString(response["detail"])
            let suffix = [detail, source].compactMap { $0 }.joined(separator: "\n")
            let extra = suffix.isEmpty ? "" : "\n\(suffix)"
            switch error {
            case "not_signed_in":
                throw CLIError(message: "You are not signed in to cmux. Run `cmux auth login`, then retry.\(extra)")
            case "session_refresh_failed":
                throw CLIError(message: "cmux could not refresh your session. Retry in a moment.\(extra)")
            case "active_already_subscribed":
                throw CLIError(message: "You already have an active subscription.\(extra)")
            case "error", "unavailable", "invalid_plan":
                let billing = billingString(response["billing"]) ?? error
                throw CLIError(message: "Billing is not available: \(billing).\(extra)")
            default:
                throw CLIError(message: "Billing request failed: \(error).\(extra)")
            }
        }
    }

    private func openBillingURL(_ rawURL: String) throws {
        guard URL(string: rawURL) != nil else {
            throw CLIError(message: "Billing returned an invalid URL.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [rawURL]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CLIError(message: "Failed to open billing URL. Run with --url and open it manually.")
        }
    }

    private func billingDisplayPlanName(planId: String, isPro: Bool?) -> String {
        if isPro == true { return "Pro" }
        switch planId.lowercased() {
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "free":
            return "Free"
        default:
            return Self.sanitizeForTerminal(planId)
        }
    }

    private func billingString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Self.sanitizeForTerminal(trimmed)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func billingBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
