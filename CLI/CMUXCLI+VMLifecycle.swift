import Foundation

extension CMUXCLI {
    func runVMLifecycleCommand(
        action: String,
        rest: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let lifecycleArgs = rest.filter { $0 != "--json" }
        guard lifecycleArgs.count == 1,
              let selector = lifecycleArgs.first,
              !selector.hasPrefix("-") else {
            throw CLIError(message: Self.vmLifecycleUsage)
        }

        let method = "vm.\(action)"
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: method,
                params: ["id": selector],
                responseTimeout: action == "restart" ? 60 : 180
            )
        } catch let notFoundError as CLIError where Self.isVMMachineNotFound(notFoundError) {
            // Keep the canonical-id fast path above. Resolve labels only after
            // the backend confirms that the raw selector is not an id.
            let listResponse: [String: Any]
            do {
                listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
            } catch {
                throw notFoundError
            }
            let resolvedID = try Self.resolveVMMachineID(selector: selector, from: listResponse)
            guard resolvedID != selector else {
                throw notFoundError
            }
            response = try client.sendV2(
                method: method,
                params: ["id": resolvedID],
                responseTimeout: action == "restart" ? 60 : 180
            )
        }

        if jsonOutput {
            print(jsonString(response))
            return
        }
        let status = (response["status"] as? String) ?? "?"
        if action == "pause" {
            let format = String(
                localized: "cli.vm.lifecycle.pause.result",
                defaultValue: "%1$@ paused (status=%2$@); cmux vm resume %3$@ wakes it"
            )
            print("OK " + String(format: format, selector, status, shellQuote(selector)))
        } else if action == "resume" {
            let format = String(
                localized: "cli.vm.lifecycle.resume.result",
                defaultValue: "%1$@ resumed (status=%2$@)"
            )
            print("OK " + String(format: format, selector, status))
        } else {
            let format = String(localized: "cli.vm.restart.result", defaultValue: "%1$@ restarted (status=%2$@)")
            print("OK " + String(format: format, selector, status))
        }
    }
}
