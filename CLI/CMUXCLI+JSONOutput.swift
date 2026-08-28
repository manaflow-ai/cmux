import Foundation

extension CMUXCLI {
    func publicSurfaceResumePayload(_ object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            var selected: [String: Any] = [:]
            for (key, value) in dictionary where !key.hasPrefix("SUBROUTER_CODEX_") {
                selected[key] = publicSurfaceResumePayload(value)
            }
            return selected
        case let array as [Any]:
            return array.map(publicSurfaceResumePayload)
        default:
            return object
        }
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
