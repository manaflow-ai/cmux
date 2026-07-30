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
        if isStandardSSHURLScheme(url.scheme) {
            return parseStandardSSHURL(url)
        }
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

    private static func isStandardSSHURLScheme(_ scheme: String?) -> Bool {
        scheme?.lowercased() == "ssh"
    }

    private static func parseStandardSSHURL(_ url: URL) -> Result<CmuxSSHURLRequest?, CmuxSSHURLParseError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.missingDestination)
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty else {
            return .failure(.conflictingDestinationParameters)
        }
        guard components.password == nil else {
            return .failure(.unsupportedParameter("password"))
        }

        let queryItems = components.queryItems ?? []
        let allowedQueryNames: Set<String> = ["title", "name", "no-focus"]
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

        guard let hostValue = components.host, !hostValue.isEmpty else {
            return .failure(.missingDestination)
        }
        let destinationHost = unbracketedStandardSSHHost(hostValue)
        guard !destinationHost.hasPrefix("-") else {
            return .failure(.destinationStartsWithDash)
        }
        guard isAllowedStandardSSHHost(hostValue) else {
            return .failure(.destinationContainsUnsafeCharacters)
        }

        let userValue = components.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userValue, !userValue.isEmpty {
            guard !userValue.hasPrefix("-") else {
                return .failure(.destinationStartsWithDash)
            }
            guard isAllowedSSHUser(userValue) else {
                return .failure(.destinationContainsUnsafeCharacters)
            }
        }
        let destination: String
        if let userValue, !userValue.isEmpty {
            destination = "\(userValue)@\(destinationHost)"
        } else {
            destination = destinationHost
        }
        guard destination.count <= maxDestinationLength else {
            return .failure(.destinationTooLong(maxLength: maxDestinationLength))
        }

        let parsedPort: Int?
        switch standardSSHURLPort(in: components) {
        case .success(let port):
            parsedPort = port
        case .failure(let error):
            return .failure(error)
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
                sshOptions: [],
                noFocus: noFocus
            )
        )
    }

    private static func standardSSHURLPort(in components: URLComponents) -> Result<Int?, CmuxSSHURLParseError> {
        if let port = components.port {
            guard port > 0, port <= 65_535 else {
                return .failure(.invalidPort)
            }
            return .success(port)
        }
        guard !standardSSHURLHasExplicitPort(in: components) else {
            return .failure(.invalidPort)
        }
        return .success(nil)
    }

    private static func standardSSHURLHasExplicitPort(in components: URLComponents) -> Bool {
        guard let string = components.string,
              let authorityStart = string.range(of: "://")?.upperBound else {
            return false
        }

        var authority = string[authorityStart...]
        if let authorityEnd = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<authorityEnd]
        }
        if let userInfoEnd = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: userInfoEnd)...]
        }

        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else { return false }
            let afterBracket = authority.index(after: closingBracket)
            return afterBracket < authority.endIndex && authority[afterBracket] == ":"
        }

        return authority.contains(":")
    }

    private static func unbracketedStandardSSHHost(_ host: String) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func isAllowedStandardSSHHost(_ value: String) -> Bool {
        if isAllowedSSHHost(value) {
            return true
        }
        guard !containsUnsafeHiddenCharacter(value),
              value.contains(":"),
              !value.hasPrefix("["),
              !value.hasSuffix("]") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz:.%")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
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
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._%+=,:-")
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
        if value.range(of: #"[^A-Za-z0-9_./:=+@%-]"#, options: .regularExpression) == nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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

enum CmuxNavigationURLParseError: Error, Equatable {
    case unsupportedURLShape
    case invalidIdentifier(String)
}

struct CmuxNavigationURLRequest: Equatable {
    enum Target: Equatable {
        case workspace(UUID)
        case pane(workspaceId: UUID, paneId: UUID)
        case surface(workspaceId: UUID, surfaceId: UUID)
    }

    static var activeSupportedSchemes: Set<String> {
        [AuthEnvironment.callbackScheme.lowercased()]
    }

    let originalURL: URL
    let target: Target

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxNavigationURLRequest?, CmuxNavigationURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedURLShape)
        }

        let route = routeComponents(from: components)
        guard route.first?.lowercased() == "workspace" else {
            return .success(nil)
        }

        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            return .failure(.unsupportedURLShape)
        }

        guard route.count == 2 || route.count == 4 else {
            return .failure(.unsupportedURLShape)
        }
        guard let workspaceId = UUID(uuidString: route[1]) else {
            return .failure(.invalidIdentifier("workspace"))
        }
        if route.count == 2 {
            return .success(CmuxNavigationURLRequest(originalURL: url, target: .workspace(workspaceId)))
        }

        let childKind = route[2].lowercased()
        guard let childId = UUID(uuidString: route[3]) else {
            switch childKind {
            case "pane":
                return .failure(.invalidIdentifier("pane"))
            case "surface", "panel":
                return .failure(.invalidIdentifier("surface"))
            default:
                return .failure(.unsupportedURLShape)
            }
        }

        switch childKind {
        case "pane":
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .pane(workspaceId: workspaceId, paneId: childId)
                )
            )
        case "surface", "panel":
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .surface(workspaceId: workspaceId, surfaceId: childId)
                )
            )
        default:
            return .failure(.unsupportedURLShape)
        }
    }

    static func workspaceLink(workspaceId: UUID, scheme: String = AuthEnvironment.callbackScheme) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)"
    }

    static func paneLink(
        workspaceId: UUID,
        paneId: UUID,
        scheme: String = AuthEnvironment.callbackScheme
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"
    }

    static func surfaceLink(
        workspaceId: UUID,
        surfaceId: UUID,
        scheme: String = AuthEnvironment.callbackScheme
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func routeComponents(from components: URLComponents) -> [String] {
        var route: [String] = []
        if let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            route.append(host)
        }
        route += components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return route
    }
}

enum CmuxTextURLParseError: Error, Equatable {
    case missingText
    case textTooLong(maxLength: Int)
    case textContainsUnsafeCharacters
    case nameTooLong(maxLength: Int)
    case nameContainsUnsafeCharacters
    case titleTooLong(maxLength: Int)
    case titleContainsUnsafeCharacters
    case invalidBooleanParameter(String)
    case duplicateParameter(String)
    case unsupportedParameter(String)
    case multipleLinks
}

struct CmuxTextURLRequest: Equatable {
    enum Kind: String, Equatable {
        case prompt
        case rules
    }

    static let maxTextLength = 8_000
    static let maxNameLength = 120
    static let maxTitleLength = 160
    static let supportedSchemes: Set<String> = CmuxSSHURLRequest.supportedSchemes
    static var activeSupportedSchemes: Set<String> {
        CmuxSSHURLRequest.activeSupportedSchemes
    }

    let originalURL: URL
    let kind: Kind
    let text: String
    let name: String?
    let title: String?
    let noFocus: Bool

    var pasteText: String {
        text
    }

    private struct ParsedQueryItem {
        let name: String
        let value: String?
    }

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxTextURLRequest?, CmuxTextURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let kind = textTarget(from: url) else {
            return .success(nil)
        }
        guard !containsPathPayload(url) else {
            return .failure(.unsupportedParameter("path"))
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.missingText)
        }

        let queryItems = parsedQueryItems(from: components)
        let allowedQueryNames: Set<String> = ["text", "name", "title", "no-focus"]
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

        guard let text = exactQueryValue(namedAnyOf: ["text"], in: queryItems) else {
            return .failure(.missingText)
        }
        guard text.count <= maxTextLength else {
            return .failure(.textTooLong(maxLength: maxTextLength))
        }
        guard !containsUnsafeTextCharacter(text) else {
            return .failure(.textContainsUnsafeCharacters)
        }

        let name = normalizedQueryValue(namedAnyOf: ["name"], in: queryItems)
        if let name {
            guard name.count <= maxNameLength else {
                return .failure(.nameTooLong(maxLength: maxNameLength))
            }
            guard !containsUnsafeHiddenCharacter(name) else {
                return .failure(.nameContainsUnsafeCharacters)
            }
        }

        let title = normalizedQueryValue(namedAnyOf: ["title"], in: queryItems)
        if let title {
            guard title.count <= maxTitleLength else {
                return .failure(.titleTooLong(maxLength: maxTitleLength))
            }
            guard !containsUnsafeHiddenCharacter(title) else {
                return .failure(.titleContainsUnsafeCharacters)
            }
        }

        let noFocus: Bool
        switch normalizedBooleanValue(named: "no-focus", in: queryItems) {
        case .success(let value):
            noFocus = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(CmuxTextURLRequest(
            originalURL: url,
            kind: kind,
            text: text,
            name: name,
            title: title,
            noFocus: noFocus
        ))
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func textTarget(from url: URL) -> Kind? {
        if let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
           !host.isEmpty {
            return kind(named: host)
        }

        let firstPathComponent = url.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
        guard let firstPathComponent else { return nil }
        return kind(named: firstPathComponent)
    }

    private static func kind(named value: String) -> Kind? {
        switch value {
        case "prompt":
            return .prompt
        case "rule", "rules":
            return .rules
        default:
            return nil
        }
    }

    private static func containsPathPayload(_ url: URL) -> Bool {
        if let host = url.host?.lowercased(),
           kind(named: host) != nil {
            return !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }
        let pathComponents = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return pathComponents.first.map { kind(named: $0.lowercased()) != nil } == true && pathComponents.count > 1
    }

    private static func parsedQueryItems(from components: URLComponents) -> [ParsedQueryItem] {
        guard let query = components.percentEncodedQuery,
              !query.isEmpty else {
            return []
        }
        return query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { rawPair in
                let parts = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = percentDecodedQueryComponent(String(parts[0])) ?? String(parts[0])
                let value = parts.count > 1
                    ? percentDecodedQueryComponent(String(parts[1])) ?? String(parts[1])
                    : nil
                return ParsedQueryItem(name: name, value: value)
            }
    }

    private static func percentDecodedQueryComponent(_ value: String) -> String? {
        value.removingPercentEncoding
    }

    private static func normalizedQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func exactQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value,
              !value.isEmpty else {
            return nil
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedBooleanValue(named name: String, in queryItems: [ParsedQueryItem]) -> Result<Bool, CmuxTextURLParseError> {
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

    private static func containsUnsafeTextCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
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
