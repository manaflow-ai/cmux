import Foundation

enum CmuxSSHURLParseError: Error, Equatable {
    case missingDestination
    case destinationTooLong(maxLength: Int)
    case destinationContainsUnsafeCharacters
    case destinationStartsWithDash
    case titleTooLong(maxLength: Int)
    case titleContainsUnsafeCharacters
    case invalidPort
    case invalidIntegerParameter(String)
    case invalidHostKeyPolicy(String)
    case invalidBooleanParameter(String)
    case conflictingDestinationParameters
    case conflictingTitleParameters
    case duplicateParameter(String)
    case unsupportedParameter(String)
    case multipleLinks
}

struct CmuxSSHURLRequest: Equatable {
    static let maxDestinationLength = 256
    static let maxTitleLength = 160
    static let supportedSchemes: Set<String> = ["cmux", "cmux-nightly", "cmux-dev"]
    static var activeSupportedSchemes: Set<String> {
        [AuthEnvironment.callbackScheme.lowercased()]
    }

    let originalURL: URL
    let destination: String
    let port: Int?
    let title: String?
    let sshOptions: [String]
    let noFocus: Bool

    var cliArguments: [String] {
        var parts = ["ssh"]
        if let port {
            parts += ["--port", String(port)]
        }
        if let title = normalizedTitle {
            parts += ["--name", title]
        }
        for sshOption in sshOptions {
            parts += ["--ssh-option", sshOption]
        }
        if noFocus {
            parts.append("--no-focus")
        }
        parts.append(destination)
        return parts
    }

    var cliPreview: String {
        cliPreview(socketPath: nil)
    }

    func cliPreview(socketPath: String?) -> String {
        var parts = ["cmux"]
        if let socketPath, !socketPath.isEmpty {
            parts += ["--socket", socketPath]
        }
        parts += cliArguments
        return parts.map(Self.previewArgument).joined(separator: " ")
    }

    var displayTarget: String {
        if let port {
            return "\(destination):\(port)"
        }
        return destination
    }

    private var normalizedTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxSSHURLRequest?, CmuxSSHURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard sshTarget(from: url) else {
            return .success(nil)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.missingDestination)
        }

        let queryItems = components.queryItems ?? []
        let allowedQueryNames: Set<String> = [
            "host",
            "user",
            "port",
            "title",
            "name",
            "connect-timeout",
            "server-alive-interval",
            "server-alive-count-max",
            "host-key-policy",
            "no-focus"
        ]
        var seenQueryNames = Set<String>()
        for item in queryItems {
            let name = item.name.lowercased()
            guard allowedQueryNames.contains(name) else {
                return .failure(.unsupportedParameter(displayParameterName(item.name)))
            }
            guard seenQueryNames.insert(name).inserted else {
                return .failure(.duplicateParameter(displayParameterName(item.name)))
            }
        }
        guard !containsPathDestination(url) else {
            return .failure(.conflictingDestinationParameters)
        }

        guard let hostValue = normalizedQueryValue(namedAnyOf: ["host"], in: queryItems) else {
            return .failure(.missingDestination)
        }
        guard !hostValue.hasPrefix("-") else {
            return .failure(.destinationStartsWithDash)
        }
        guard isAllowedSSHHost(hostValue) else {
            return .failure(.destinationContainsUnsafeCharacters)
        }

        let userValue = normalizedQueryValue(namedAnyOf: ["user"], in: queryItems)
        if let userValue {
            guard !userValue.hasPrefix("-") else {
                return .failure(.destinationStartsWithDash)
            }
            guard isAllowedSSHUser(userValue) else {
                return .failure(.destinationContainsUnsafeCharacters)
            }
        }
        let destination = userValue.map { "\($0)@\(hostValue)" } ?? hostValue

        guard destination.count <= maxDestinationLength else {
            return .failure(.destinationTooLong(maxLength: maxDestinationLength))
        }

        let parsedPort: Int?
        if let portValue = normalizedQueryValue(namedAnyOf: ["port"], in: queryItems) {
            guard let value = Int(portValue), value > 0, value <= 65535 else {
                return .failure(.invalidPort)
            }
            parsedPort = value
        } else {
            parsedPort = nil
        }

        let titleValue = normalizedQueryValue(namedAnyOf: ["title"], in: queryItems)
        let nameValue = normalizedQueryValue(namedAnyOf: ["name"], in: queryItems)
        guard titleValue == nil || nameValue == nil else {
            return .failure(.conflictingTitleParameters)
        }
        let title = titleValue ?? nameValue
        if let title {
            guard title.count <= maxTitleLength else {
                return .failure(.titleTooLong(maxLength: maxTitleLength))
            }
            guard !containsUnsafeHiddenCharacter(title) else {
                return .failure(.titleContainsUnsafeCharacters)
            }
        }

        let sshOptions: [String]
        switch structuredSSHOptions(from: queryItems) {
        case .success(let options):
            sshOptions = options
        case .failure(let error):
            return .failure(error)
        }

        let noFocus: Bool
        switch normalizedBooleanValue(named: "no-focus", in: queryItems) {
        case .success(let value):
            noFocus = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(
            CmuxSSHURLRequest(
                originalURL: url,
                destination: destination,
                port: parsedPort,
                title: title,
                sshOptions: sshOptions,
                noFocus: noFocus
            )
        )
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func sshTarget(from url: URL) -> Bool {
        if let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
           !host.isEmpty {
            return host == "ssh"
        }

        let firstPathComponent = url.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
        return firstPathComponent == "ssh"
    }

    private static func containsPathDestination(_ url: URL) -> Bool {
        if let host = url.host?.lowercased(), host == "ssh" {
            return !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }
        let pathComponents = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return pathComponents.first?.lowercased() == "ssh" && pathComponents.count > 1
    }

    private static func normalizedQueryValue(namedAnyOf names: Set<String>, in queryItems: [URLQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func structuredSSHOptions(from queryItems: [URLQueryItem]) -> Result<[String], CmuxSSHURLParseError> {
        var options: [String] = []
        if let value = normalizedQueryValue(namedAnyOf: ["connect-timeout"], in: queryItems) {
            switch boundedInteger(value, parameter: "connect-timeout", range: 1...600) {
            case .success(let seconds):
                options.append("ConnectTimeout=\(seconds)")
            case .failure(let error):
                return .failure(error)
            }
        }
        if let value = normalizedQueryValue(namedAnyOf: ["server-alive-interval"], in: queryItems) {
            switch boundedInteger(value, parameter: "server-alive-interval", range: 1...3600) {
            case .success(let seconds):
                options.append("ServerAliveInterval=\(seconds)")
            case .failure(let error):
                return .failure(error)
            }
        }
        if let value = normalizedQueryValue(namedAnyOf: ["server-alive-count-max"], in: queryItems) {
            switch boundedInteger(value, parameter: "server-alive-count-max", range: 1...100) {
            case .success(let count):
                options.append("ServerAliveCountMax=\(count)")
            case .failure(let error):
                return .failure(error)
            }
        }
        if let value = normalizedQueryValue(namedAnyOf: ["host-key-policy"], in: queryItems) {
            switch value.lowercased() {
            case "accept-new":
                options.append("StrictHostKeyChecking=accept-new")
            case "ask":
                options.append("StrictHostKeyChecking=ask")
            case "strict", "yes":
                options.append("StrictHostKeyChecking=yes")
            default:
                return .failure(.invalidHostKeyPolicy("host-key-policy"))
            }
        }
        return .success(options)
    }

    private static func boundedInteger(_ value: String, parameter: String, range: ClosedRange<Int>) -> Result<Int, CmuxSSHURLParseError> {
        guard !containsUnsafeHiddenCharacter(value),
              value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let integer = Int(value),
              range.contains(integer) else {
            return .failure(.invalidIntegerParameter(parameter))
        }
        return .success(integer)
    }

    private static func normalizedBooleanValue(named name: String, in queryItems: [URLQueryItem]) -> Result<Bool, CmuxSSHURLParseError> {
        guard let item = queryItems.first(where: { $0.name.lowercased() == name }) else {
            return .success(false)
        }
        guard let rawValue = item.value else {
            return .success(true)
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return .success(true)
        }
        switch normalized {
        case "1", "true", "yes", "on":
            return .success(true)
        case "0", "false", "no", "off":
            return .success(false)
        default:
            return .failure(.invalidBooleanParameter(displayParameterName(item.name)))
        }
    }

    private static func isAllowedSSHHost(_ value: String) -> Bool {
        guard !containsUnsafeHiddenCharacter(value) else { return false }
        if value.hasPrefix("[") || value.hasSuffix("]") {
            guard value.hasPrefix("["), value.hasSuffix("]") else { return false }
            let inner = String(value.dropFirst().dropLast())
            guard !inner.isEmpty else { return false }
            let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz:.%")
            return inner.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._%-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isAllowedSSHUser(_ value: String) -> Bool {
        guard !containsUnsafeHiddenCharacter(value) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._%+=-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func containsUnsafeHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func previewArgument(_ value: String) -> String {
        if value.range(of: #"[^A-Za-z0-9_./:=+@%\-\[\]]"#, options: .regularExpression) == nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func displayParameterName(_ name: String) -> String {
        if name.isEmpty || containsUnsafeHiddenCharacter(name) {
            return "?"
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "?"
        }
        let prefix = String(name.prefix(64))
        return prefix.count == name.count ? name : "\(prefix)..."
    }
}
