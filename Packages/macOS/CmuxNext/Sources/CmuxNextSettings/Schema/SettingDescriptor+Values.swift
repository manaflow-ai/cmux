import CmuxNextDesign
import Foundation

/// A row's value logic is Rust's (`schema.*` ops, cmux-tui/crates/cmux-config/src/app_ops/schema.rs):
/// these read it through ``SettingsRust``. The art catalog stays here: a retired painting id Rust has
/// not been told about comes back as `{need: {art}}`, answered with ``BackdropArt``'s stand-in.
extension SettingDescriptor {
    /// The value stored in `root`, or nil when the key is absent. A renamed
    /// key that is absent reads its old key, as the parser does, so Settings
    /// shows the value the app applies.
    public func storedValue(in root: JSONValue) -> JSONValue? {
        Self.present(reading("schema.stored", root)["value"])
    }

    /// The stored value when it is valid, else the default (what the app
    /// applies: a bad value keeps the default, with a diagnostic).
    public func effectiveValue(in root: JSONValue) -> JSONValue? {
        Self.present(reading("schema.effective", root)["value"])
    }

    /// Whether the app would apply `value` without a diagnostic. Numbers
    /// outside the range are refused here, although the parser clamps them,
    /// so the window never writes a value that loads with a warning.
    public func accepts(_ value: JSONValue) -> Bool {
        SettingsRust.answer("schema.accepts", ["key": .string(id), "value": value])["accepted"]?.boolValue ?? false
    }

    /// Whether the key differs from its default (the row shows Reset).
    public func isCustomized(in root: JSONValue) -> Bool {
        reading("schema.customized", root)["customized"]?.boolValue ?? false
    }

    /// The value a toggle flips to: the opposite of what applies now, so a
    /// setting whose default is on turns off on its first toggle.
    public func toggledValue(in root: JSONValue) -> Bool? {
        reading("schema.toggled", root)["value"]?.boolValue
    }

    /// `op`'s reply for this row and `root`, asked again with the art catalog's answer when Rust
    /// needs it (an old `appearance.backdropArt` id read for `appearance.background`).
    func reading(_ op: String, _ root: JSONValue) -> JSONValue {
        let request: [String: JSONValue] = ["key": .string(id), "root": root]
        let reply = SettingsRust.answer(op, .object(request))
        guard let art = reply["need"]?["art"]?.stringValue else { return reply }
        var asked = request
        asked["arts"] = .object([art: BackdropArt(id: art).map { .string($0.rawValue) } ?? .null])
        return SettingsRust.answer(op, .object(asked))
    }

    /// `value` unless it is missing or null (a reply's "no value").
    static func present(_ value: JSONValue?) -> JSONValue? {
        guard let value, !value.isNull else { return nil }
        return value
    }

    /// `text` as an origin (`scheme://host[:port]`, scheme and host lowercased)
    /// when it is an http or https address with a host and nothing else: no user
    /// info, no path other than "/", no query, no fragment. The same rule as
    /// cmux-config `is_http_origin` and the Settings page's `httpOrigin`.
    static func httpOrigin(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), !text.contains("?"), !text.contains("#"), !text.contains("@"),
              var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = scheme
        components.path = ""
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        return components.url
    }
}
