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
        } catch let error as CLIError where Self.isVMMachineNotFound(error) {
            // Keep the canonical-id fast path above. Resolve labels only after
            // the backend confirms that the raw selector is not an id.
            let listResponse: [String: Any]
            do {
                listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
            } catch {
                throw error
            }
            let resolvedID = try Self.resolveVMMachineID(selector: selector, from: listResponse)
            guard resolvedID != selector else {
                throw error
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
            print("OK (selector) paused (status=(status)); cmux vm resume (selector) wakes it")
        } else if action == "resume" {
            print("OK (selector) resumed (status=(status))")
        } else {
            let format = String(localized: "cli.vm.restart.result", defaultValue: "%1$@ restarted (status=%2$@)")
            print(String(format: format, selector, status))
        }
    }
}
