public import Foundation
public import AppKit

/// Navigation-policy decisions derived from the insecure-HTTP allowlist:
/// whether a plaintext `http://` URL should be blocked, and whether a one-shot
/// per-host bypass applies to a pending navigation. These are stateless
/// transforms over the allowlist owned by ``BrowserInsecureHTTPSettings``.
extension BrowserInsecureHTTPSettings {
    /// Whether `url` should be blocked from loading over plaintext HTTP, reading
    /// the allowlist from `defaults`.
    ///
    /// - Parameters:
    ///   - url: The candidate navigation URL.
    ///   - defaults: The defaults to read the allowlist from.
    /// - Returns: `true` when the URL is plaintext HTTP and its host is not
    ///   allowlisted.
    public static func shouldBlock(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldBlock(
            url,
            rawAllowlist: defaults.string(forKey: allowlistKey)
        )
    }

    /// Whether `url` should be blocked from loading over plaintext HTTP per a raw
    /// allowlist string.
    ///
    /// - Parameters:
    ///   - url: The candidate navigation URL.
    ///   - rawAllowlist: The raw allowlist string, if any.
    /// - Returns: `true` when the URL is plaintext HTTP and its host is not
    ///   allowlisted. A non-normalizable host on an HTTP URL is blocked.
    public static func shouldBlock(_ url: URL, rawAllowlist: String?) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        guard let host = normalizeHost(url.host ?? "") else { return true }
        return !isHostAllowed(host, rawAllowlist: rawAllowlist)
    }

    /// Whether a pending one-shot insecure-HTTP bypass applies to `url`,
    /// consuming it when it does.
    ///
    /// - Parameters:
    ///   - url: The candidate navigation URL.
    ///   - bypassHostOnce: The host granted a one-time bypass, if any. Cleared to
    ///     `nil` when this navigation consumes the bypass.
    /// - Returns: `true` when `url` is plaintext HTTP whose normalized host
    ///   matches the pending bypass host (which is then consumed).
    public static func shouldConsumeOneTimeBypass(_ url: URL, bypassHostOnce: inout String?) -> Bool {
        guard let bypassHost = bypassHostOnce else { return false }
        guard url.scheme?.lowercased() == "http",
              let host = normalizeHost(url.host ?? "") else {
            return false
        }
        guard host == bypassHost else { return false }
        bypassHostOnce = nil
        return true
    }

    /// Whether the insecure-HTTP warning alert's suppression checkbox should
    /// persist the host to the allowlist for the given dismissal.
    ///
    /// - Parameters:
    ///   - response: The modal response the user chose.
    ///   - suppressionEnabled: Whether the "always allow this host" checkbox is on.
    /// - Returns: `true` only when suppression is enabled and the user chose to
    ///   open in the default browser or proceed in cmux (not cancel).
    public static func shouldPersistAllowlistSelection(
        response: NSApplication.ModalResponse,
        suppressionEnabled: Bool
    ) -> Bool {
        guard suppressionEnabled else { return false }
        return response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
    }
}
