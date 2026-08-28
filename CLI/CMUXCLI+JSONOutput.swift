import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func publicSurfaceResumePayload(_ object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            var selected: [String: Any] = [:]
            for (key, value) in dictionary
                where !key.hasPrefix("SUBROUTER_CODEX_")
                    && key != SubrouterCodexResumeRouting.launchBoundEnvironmentKey
                    && key != "CMUX_CUSTOM_CODEX_PATH" {
                selected[key] = publicSurfaceResumePayload(value)
            }
            return selected
        case let array as [Any]:
            return array.map(publicSurfaceResumePayload)
        case let value as String where containsPrivateSubrouterRoutingMetadata(value):
            return NSNull()
        default:
            return object
        }
    }

    private func containsPrivateSubrouterRoutingMetadata(_ value: String) -> Bool {
        if value.contains("SUBROUTER_CODEX_") || value.contains("model_providers.subrouter.") {
            return true
        }
        let normalized = value.filter {
            !$0.isWhitespace && $0 != "\"" && $0 != "'"
        }
        // `sr`/`subrouter`/`cx` are user-facing launcher names and remain public;
        // only captured routing inputs and internal provider configuration are private.
        return normalized.contains("model_provider=subrouter")
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
