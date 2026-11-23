import CCmuxActionCatalogFFI
import Foundation

/// One JSON request to the Rust action catalog (`cmux_action_catalog_call`, linked through
/// CCmuxAppFFI): the menu bar and profile menu rows and `when` clause parsing and text are built
/// there; this module decodes the reply into its Swift values.
nonisolated enum RustCatalogCall {
    /// The language this module's strings resolve to (`app.language`, ``AppLanguage``): the chosen
    /// language's `.lproj`, else the bundle's negotiated localization. Read on each call, so the
    /// text follows a live language change as `String(localized:bundle: .localizedModule)` did.
    static var language: String {
        let bundle = Bundle.localizedModule
        if bundle.bundleURL.pathExtension == "lproj" {
            return bundle.bundleURL.deletingPathExtension().lastPathComponent
        }
        return bundle.preferredLocalizations.first ?? "en"
    }

    /// The reply to `request` (an object with an `op`), nil when the library refuses it.
    static func reply(_ request: [String: Any]) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { bytes in
            cmux_action_catalog_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &pointer, &length)
        }
        guard status == 0, let pointer else { return nil }
        defer { cmux_action_catalog_reply_free(pointer, length) }
        let data = Data(bytesNoCopy: pointer, count: length, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
