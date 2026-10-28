/// A ``PageHostBridge`` that can hand the router's envelopes to the page as data instead of a script:
/// the Chromium page push channel (``ChromiumPageHostBridge``, fork API 43), as Chrome's WebUI pages
/// get Mojo messages instead of `WebUI::CallJavascriptFunction` scripts
/// (content/browser/webui/web_ui_impl.cc).
@MainActor public protocol PageHostPushing: PageHostBridge {
    /// Whether envelopes go as data now (``push(envelopes:)``); false: as scripts (``PageHostBridge/evaluate(_:)``).
    var pushesEnvelopes: Bool { get }
    /// Hands one run of envelopes, as their JSON array (``PageRouter/receiveManyData(_:)``), to the page
    /// after every script and push the bridge got before it.
    func push(envelopes json: String)
}
