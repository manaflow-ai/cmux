import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func publicSurfaceResumePayload(_ object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            var selected: [String: Any] = [:]
            let commandContainsPrivateEnvironment = containsPrivateSubrouterRoutingKey(
                in: dictionary["environment"]
            )
            let legacyCommandContainsPrivateEnvironment = commandContainsPrivateEnvironment
                || containsPrivateSubrouterRoutingKey(
                    in: (dictionary["launch_command"] as? [String: Any])?["environment"]
                )
            for (key, value) in dictionary
                where !isPrivateSubrouterRoutingKey(key) {
                if key == "command", commandContainsPrivateEnvironment {
                    selected[key] = NSNull()
                } else if key == "legacy_command", legacyCommandContainsPrivateEnvironment {
                    selected[key] = NSNull()
                } else if key == "arguments", let arguments = value as? [String] {
                    selected[key] = SubrouterCodexResumeRouting()
                        .removingPrivateRoutingArguments(from: arguments)
                } else {
                    selected[key] = publicSurfaceResumePayload(value)
                }
            }
            return selected
        case let array as [Any]:
            return array.map(publicSurfaceResumePayload)
        default:
            return object
        }
    }

    private func containsPrivateSubrouterRoutingKey(in value: Any?) -> Bool {
        (value as? [String: Any])?
            .keys
            .contains(where: isPrivateSubrouterRoutingKey) == true
    }

    private func isPrivateSubrouterRoutingKey(_ key: String) -> Bool {
        key.hasPrefix("SUBROUTER_CODEX_")
            || key == SubrouterCodexResumeRouting.launchBoundEnvironmentKey
            || key == "CMUX_CUSTOM_CODEX_PATH"
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.sortedKeys)
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }
}
