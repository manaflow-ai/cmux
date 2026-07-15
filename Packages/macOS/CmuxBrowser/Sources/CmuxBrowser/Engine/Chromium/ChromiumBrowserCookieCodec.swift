import Foundation

/// Converts cookie values between the engine-neutral model and Chrome DevTools Protocol.
struct ChromiumBrowserCookieCodec {
    func cookies(from response: CDPJSONValue) throws -> [BrowserEngineCookie] {
        guard let rows = response.objectValue?["cookies"]?.arrayValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium returned an invalid cookie payload.")
        }
        return try rows.map { row in
            guard let object = row.objectValue,
                  let name = object["name"]?.stringValue,
                  let value = object["value"]?.stringValue,
                  let domain = object["domain"]?.stringValue,
                  let path = object["path"]?.stringValue else {
                throw BrowserEngineSessionError.chromiumProtocol(
                    "Chromium returned an invalid cookie payload."
                )
            }
            let expiresDate: Date? = if case .number(let seconds) = object["expires"], seconds > 0 {
                Date(timeIntervalSince1970: seconds)
            } else {
                nil
            }
            return BrowserEngineCookie(
                name: name,
                value: value,
                domain: domain,
                path: path,
                isSecure: object["secure"] == .bool(true),
                isHTTPOnly: object["httpOnly"] == .bool(true),
                expiresDate: expiresDate
            )
        }
    }

    func setParameters(for cookie: BrowserEngineCookie) -> [String: CDPJSONValue] {
        var parameters: [String: CDPJSONValue] = [
            "name": .string(cookie.name),
            "value": .string(cookie.value),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
            "secure": .bool(cookie.isSecure),
            "httpOnly": .bool(cookie.isHTTPOnly),
        ]
        if let expiresDate = cookie.expiresDate {
            parameters["expires"] = .number(expiresDate.timeIntervalSince1970)
        }
        return parameters
    }

    func deleteParameters(for cookie: BrowserEngineCookie) -> [String: CDPJSONValue] {
        [
            "name": .string(cookie.name),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
        ]
    }
}
