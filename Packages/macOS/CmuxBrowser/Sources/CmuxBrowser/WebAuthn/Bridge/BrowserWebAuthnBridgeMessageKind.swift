/// The three native bridge operations the page-world WebAuthn shim can invoke.
///
/// The raw values match the `kind` field the injected JavaScript posts through
/// the `cmuxWebAuthn` message handler.
public enum BrowserWebAuthnBridgeMessageKind: String {
    /// Query native passkey capabilities (no payload).
    case capabilities
    /// Run a `navigator.credentials.create` ceremony.
    case createCredential
    /// Run a `navigator.credentials.get` ceremony.
    case getCredential
}
