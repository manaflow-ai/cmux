import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Removes private Subrouter routing metadata from a resume payload.
    ///
    /// A captured custom Codex path is treated as private only when the payload
    /// carries Subrouter routing, where it can name the routed binary. An
    /// ordinary Codex surface keeps its path and resume command.
    func publicSurfaceResumePayload(_ object: Any) -> Any {
        publicSurfaceResumePayload(object, routed: containsSubrouterRouting(object))
    }

    private func publicSurfaceResumePayload(_ object: Any, routed: Bool) -> Any {
        let isPrivateKey = { (key: String) in
            self.isPrivateSubrouterRoutingKey(key, routed: routed)
        }
        let containsPrivateSubrouterRoutingKey = { (value: Any?) in
            (value as? [String: Any])?.keys.contains(where: isPrivateKey) == true
        }
        let privateSubrouterRoutingValues = { (value: Any?) -> Set<String> in
            guard let environment = value as? [String: Any] else { return [] }
            return Set(environment.compactMap { key, value in
                guard isPrivateKey(key), let value = value as? String else {
                    return nil
                }
                return value
            })
        }
        switch object {
        case let dictionary as [String: Any]:
            var selected: [String: Any] = [:]
            let directPrivateEnvironment = dictionary["environment"]
            let nestedLaunchEnvironment = (dictionary["launch_command"] as? [String: Any])?["environment"]
            // Both rendered commands can carry values from either environment:
            // the binding's own and the captured launch command's.
            let commandContainsPrivateEnvironment =
                containsPrivateSubrouterRoutingKey(directPrivateEnvironment)
                || containsPrivateSubrouterRoutingKey(nestedLaunchEnvironment)
            let privateRoutingValues = privateSubrouterRoutingValues(directPrivateEnvironment)
                .union(privateSubrouterRoutingValues(nestedLaunchEnvironment))
            for (key, value) in dictionary
                where !isPrivateKey(key) {
                if key == "command", commandContainsPrivateEnvironment {
                    selected[key] = NSNull()
                } else if key == "legacy_command", commandContainsPrivateEnvironment {
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
                    selected[key] = publicSurfaceResumePayload(value, routed: routed)
                }
            }
            return selected
        case let array as [Any]:
            return array.map { publicSurfaceResumePayload($0, routed: routed) }
        default:
            return object
        }
    }

    private func containsSubrouterRouting(_ object: Any) -> Bool {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.contains { key, value in
                isPrivateSubrouterRoutingKey(key, routed: false) || containsSubrouterRouting(value)
            }
        case let array as [Any]:
            return array.contains(where: containsSubrouterRouting)
        default:
            return false
        }
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

    private func isPrivateSubrouterRoutingKey(_ key: String, routed: Bool) -> Bool {
        key.hasPrefix("SUBROUTER_CODEX_")
            || key == SubrouterCodexResumeRouting.launchBoundEnvironmentKey
            || (routed && key == "CMUX_CUSTOM_CODEX_PATH")
    }

    func jsonString(_ object: Any, prettyPrinted: Bool = true) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }
}
