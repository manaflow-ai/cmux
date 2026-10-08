internal import Foundation

/// Safe, canonical SSH authentication failures emitted by OpenSSH.
///
/// The relay receives arbitrary stderr from the user's SSH configuration. Only
/// the stable authentication markers below are promoted to user-facing state;
/// the original stderr is never logged or copied into a parked-session detail.
enum RemoteRelayAuthenticationFailure: Equatable, Sendable {
    case permissionDenied(methods: String)
    case tooManyAuthenticationFailures

    var methodLabel: String {
        switch self {
        case .permissionDenied(let methods):
            return methods
        case .tooManyAuthenticationFailures:
            return String(
                localized: "remoteSession.authentication.tooManyFailures",
                defaultValue: "too many authentication failures"
            )
        }
    }

    var logLabel: String {
        switch self {
        case .permissionDenied:
            return "permission-denied"
        case .tooManyAuthenticationFailures:
            return "too-many-authentication-failures"
        }
    }

    /// A bounded diagnostic retained only to classify the termination later.
    var canonicalDiagnostic: String {
        switch self {
        case .permissionDenied(let methods):
            return "Permission denied (\(methods))."
        case .tooManyAuthenticationFailures:
            return "Too many authentication failures."
        }
    }

    static func detect(in detail: String) -> Self? {
        let lines = detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            guard !line.lowercased().hasPrefix("debug") else { continue }
            if let methods = permissionDeniedMethods(in: line) {
                return .permissionDenied(methods: methods)
            }
            if line == "Too many authentication failures." ||
                line == "Too many authentication failures" ||
                (line.hasPrefix("Received disconnect from ") &&
                    line.hasSuffix(": Too many authentication failures")) {
                return .tooManyAuthenticationFailures
            }
        }
        return nil
    }

    private static func permissionDeniedMethods(in line: String) -> String? {
        let marker = "Permission denied ("
        guard line.hasSuffix(")."),
              let markerRange = line.range(of: marker) else {
            return nil
        }
        let prefix = line[..<markerRange.lowerBound]
        guard prefix.isEmpty || prefix.contains("@") || prefix == "ssh: " else {
            return nil
        }
        let methods = String(line[markerRange.upperBound...].dropLast(2))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !methods.isEmpty,
              methods.allSatisfy(allowedAuthenticationMethods.contains) else {
            return nil
        }
        return methods.joined(separator: ", ")
    }

    private static let allowedAuthenticationMethods: Set<String> = [
        "publickey",
        "password",
        "keyboard-interactive",
        "gssapi-with-mic",
        "gssapi-keyex",
        "hostbased",
        "none",
    ]
}
