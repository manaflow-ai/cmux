import Foundation

/// JavaScript builders and parameter normalization for the `browser storage.*`
/// control commands (`storage.get`, `storage.set`, `storage.clear`).
///
/// Every string returned here is byte-identical to the script the corresponding
/// `v2BrowserStorage*` method previously assembled inline in `TerminalController`;
/// only the assembly moved. The owning `@MainActor` controller keeps the WebKit
/// evaluation seam and the per-surface ref/workspace state, normalizes the raw
/// result via ``BrowserControlService/normalizeJSValue(_:isUndefinedSentinel:)``,
/// and composes the RPC reply, so the wire output is unchanged.
extension BrowserControlService {
    /// Normalizes the requested Web Storage area to either `"session"` or
    /// `"local"`, defaulting to `"local"` for any unrecognized request.
    ///
    /// Mirrors the previous `v2BrowserStorageType`: it reads the `storage` key,
    /// then the legacy `type` key, lowercases it, and returns `"session"` only for
    /// an exact `"session"` match. Any other value (including a missing one) maps
    /// to `"local"`. Each key is read with the same whitespace-trim / empty-to-nil
    /// semantics the controller's `v2String` parameter accessor applies, so the
    /// fall-through to `type` and the default to `"local"` are byte-identical.
    /// - Parameter params: the v2 request parameters.
    /// - Returns: `"session"` or `"local"`.
    public func storageType(params: [String: Any]) -> String {
        let type = (trimmedString(params["storage"]) ?? trimmedString(params["type"]) ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    /// Reads a JSON parameter as a non-empty trimmed string, matching the
    /// controller's `v2String` accessor (trims whitespace/newlines, returns `nil`
    /// for a missing, non-string, or empty-after-trim value).
    private func trimmedString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the `storage.get` page-world script.
    ///
    /// When `key` is `nil` the script returns every entry of the chosen storage
    /// area as an object; otherwise it returns the single item. Returns
    /// `{ ok: false, error: 'not_available' }` when the storage area is absent.
    /// Byte-identical to the script previously inlined in `v2BrowserStorageGet`.
    /// - Parameters:
    ///   - storageType: `"session"` or `"local"`, as returned by ``storageType(params:)``.
    ///   - key: the specific key to read, or `nil` to read the whole area.
    /// - Returns: a self-invoking JavaScript expression.
    public func storageGetScript(storageType: String, key: String?) -> String {
        let typeLiteral = jsonLiteral(storageType)
        let keyLiteral = key.map(jsonLiteral) ?? "null"
        return """
        (() => {
          const type = String(\(typeLiteral));
          const key = \(keyLiteral);
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          if (key == null) {
            const out = {};
            for (let i = 0; i < st.length; i++) {
              const k = st.key(i);
              out[k] = st.getItem(k);
            }
            return { ok: true, value: out };
          }
          return { ok: true, value: st.getItem(String(key)) };
        })()
        """
    }

    /// Builds the `storage.set` page-world script.
    ///
    /// Writes `value` (coerced to a string, with `null` written as the empty
    /// string) under `key` in the chosen storage area. Returns
    /// `{ ok: false, error: 'not_available' }` when the area is absent.
    /// Byte-identical to the script previously inlined in `v2BrowserStorageSet`.
    /// - Parameters:
    ///   - storageType: `"session"` or `"local"`, as returned by ``storageType(params:)``.
    ///   - key: the storage key to write.
    ///   - valueLiteral: the already-encoded JavaScript value literal (the caller
    ///     normalizes the raw value and renders it via ``jsonLiteral(_:)`` so the
    ///     controller keeps ownership of the sentinel normalization seam).
    /// - Returns: a self-invoking JavaScript expression.
    public func storageSetScript(storageType: String, key: String, valueLiteral: String) -> String {
        let typeLiteral = jsonLiteral(storageType)
        let keyLiteral = jsonLiteral(key)
        return """
        (() => {
          const type = String(\(typeLiteral));
          const key = String(\(keyLiteral));
          const value = \(valueLiteral);
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.setItem(key, value == null ? '' : String(value));
          return { ok: true };
        })()
        """
    }

    /// Builds the `storage.clear` page-world script.
    ///
    /// Clears every entry of the chosen storage area. Returns
    /// `{ ok: false, error: 'not_available' }` when the area is absent.
    /// Byte-identical to the script previously inlined in `v2BrowserStorageClear`.
    /// - Parameter storageType: `"session"` or `"local"`, as returned by ``storageType(params:)``.
    /// - Returns: a self-invoking JavaScript expression.
    public func storageClearScript(storageType: String) -> String {
        let typeLiteral = jsonLiteral(storageType)
        return """
        (() => {
          const type = String(\(typeLiteral));
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.clear();
          return { ok: true };
        })()
        """
    }
}
