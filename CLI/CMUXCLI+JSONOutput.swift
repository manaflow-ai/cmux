import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func publicSurfaceResumePayload(_ object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            var selected: [String: Any] = [:]
            let directPrivateEnvironment = dictionary["environment"]
            let nestedLaunchEnvironment = (dictionary["launch_command"] as? [String: Any])?["environment"]
            let commandContainsPrivateEnvironment = containsPrivateSubrouterRoutingKey(
                in: directPrivateEnvironment
            )
            let legacyCommandContainsPrivateEnvironment = commandContainsPrivateEnvironment
                || containsPrivateSubrouterRoutingKey(
                    in: nestedLaunchEnvironment
                )
            let privateRoutingValues = privateSubrouterRoutingValues(in: directPrivateEnvironment)
                .union(privateSubrouterRoutingValues(in: nestedLaunchEnvironment))
            for (key, value) in dictionary
                where !isPrivateSubrouterRoutingKey(key) {
                if key == "command", commandContainsPrivateEnvironment {
                    selected[key] = NSNull()
                } else if key == "legacy_command", legacyCommandContainsPrivateEnvironment {
                    selected[key] = NSNull()
                } else if (key == "arguments" || key == "prepared_arguments"),
                          let arguments = value as? [String] {
                    selected[key] = publicRoutingArguments(
                        arguments,
                        privateValues: privateRoutingValues
                    )
                } else if let value = value as? String, privateRoutingValues.contains(value) {
                    selected[key] = NSNull()
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

    private func privateSubrouterRoutingValues(in value: Any?) -> Set<String> {
        guard let environment = value as? [String: Any] else { return [] }
        return Set(environment.compactMap { key, value in
            guard isPrivateSubrouterRoutingKey(key), let value = value as? String else {
                return nil
            }
            return value
        })
    }

    private func publicRoutingArguments(
        _ arguments: [String],
        privateValues: Set<String>
    ) -> [Any] {
        SubrouterCodexResumeRouting()
            .removingPrivateRoutingArguments(from: arguments)
            .map { argument -> Any in
                privateValues.contains(argument) ? NSNull() : argument
            }
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
