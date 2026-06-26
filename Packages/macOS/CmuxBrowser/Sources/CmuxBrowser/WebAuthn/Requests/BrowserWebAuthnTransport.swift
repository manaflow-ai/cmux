/// A WebAuthn authenticator transport, as serialized in credential descriptors.
public enum BrowserWebAuthnTransport: String {
    case ble
    case hybrid
    case `internal`
    case nfc
    case usb
}
