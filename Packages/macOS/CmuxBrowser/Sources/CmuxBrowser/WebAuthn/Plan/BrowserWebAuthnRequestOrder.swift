/// The order in which platform and security-key authorization requests are
/// presented to the user during a native passkey ceremony.
public enum BrowserWebAuthnRequestOrder {
    case platformFirst
    case securityKeyFirst
}
