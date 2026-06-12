import Foundation


/// Native WebAuthn bridge for `WKWebView`.
///
/// The page world overrides `navigator.credentials.create/get`, serializes the
/// public-key request options, and asks the native bridge to run the browser's
/// WebAuthn ceremony with AuthenticationServices. Native results are then
/// marshalled back into JS objects that match the browser credential shape.
enum BrowserWebAuthnBridgeContract {
    static let handlerName = "cmuxWebAuthn"
}
