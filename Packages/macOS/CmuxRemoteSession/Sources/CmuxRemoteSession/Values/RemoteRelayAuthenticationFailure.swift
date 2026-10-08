import Foundation

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
            return "too many authentication failures"
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
            if let methods = permissionDeniedMethods(in: line) {
                return .permissionDenied(methods: methods)
            }
            if line.localizedCaseInsensitiveContains("too many authentication failures") {
                return .tooManyAuthenticationFailures
            }
        }
        return nil
    }

    private static func permissionDeniedMethods(in line: String) -> String? {
        let marker = "Permission denied ("
        guard let markerRange = line.range(of: marker, options: .caseInsensitive),
              let end = line[markerRange.upperBound...].firstIndex(of: ")") else {
            return nil
        }
        let methods = String(line[markerRange.upperBound..<end])
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
        "hostbased",
        "none",
    ]
}
