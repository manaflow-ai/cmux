public import CmuxNextCloud
import CmuxNextDesign

extension CloudConfiguration {
    /// The line under this build's cmux Sign In, in the person's language ("Signs in to cmux.com",
    /// "Signs in to Development backend · dev-abc.cmux.dev"): Rust's ``backendLabel`` through
    /// `SignInButton.backendLine`. Nil for the placeholder configuration.
    public var signInBackendLine: String? {
        backendLabel.map { SignInButton.backendLine(kind: $0.kind, title: $0.title, detail: $0.detail) }
    }
}
