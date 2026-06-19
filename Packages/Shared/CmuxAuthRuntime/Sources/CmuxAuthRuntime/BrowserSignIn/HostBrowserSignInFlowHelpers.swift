import Foundation

/// MainActor-confined once-guard for racing continuation resumes.
@MainActor
final class ResumeOnceFlag {
    var fired = false
}

func authCallbackState(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "cmux_auth_state" })?
        .value
}

func redactedAuthState(_ state: String) -> String {
    "\(state.prefix(8))..."
}

func authCallbackSummary(_ url: URL) -> String {
    let scheme = url.scheme ?? "nil"
    let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .map(\.name)
        .joined(separator: ",") ?? ""
    return "scheme=\(scheme) target=\(target.isEmpty ? "nil" : target) queryKeys=\(queryItems.isEmpty ? "none" : queryItems)"
}
