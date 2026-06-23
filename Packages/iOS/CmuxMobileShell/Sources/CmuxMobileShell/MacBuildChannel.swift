import Foundation

/// Derives a short, user-facing build-channel label for a Mac from what its
/// presence heartbeat reports — its bundle id and dev tag — so the Computers
/// screen can show whether a host is a DEV build (and which tag), Nightly, RC,
/// Staging, or Stable.
///
/// The dev tag is the primary DEV signal: a tagged `reload.sh` build sets
/// `CMUX_TAG`, so any non-`"default"` tag means a DEV build and the tag is the
/// thing worth showing. Otherwise the channel comes from the bundle-id suffix.
///
public struct MacBuildChannel: Sendable {
    /// Create a build-channel labeler.
    public init() {}

    /// A label like `"DEV · my-tag"`, `"Nightly"`, `"RC"`, `"Staging"`, or
    /// `"Stable"`, or `nil` when there is nothing identifiable to show (an older
    /// host that reports neither a meaningful tag nor a known bundle id).
    public func label(bundleID: String?, tag: String?) -> String? {
        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let devTag = (trimmedTag?.isEmpty == false && trimmedTag != "default") ? trimmedTag : nil
        if let devTag {
            return "DEV · \(devTag)"
        }

        // The channel is the component RIGHT AFTER the base bundle id; a tagged
        // build appends a further `.slug` (e.g. `com.cmuxterm.app.nightly.my-tag`,
        // `com.cmuxterm.app.rc`), so match the component, not the suffix. Mirrors
        // the canonical `SocketPathMarkerFiles.variant` on macOS — kept in sync as
        // channels are added (Stable/Nightly/Staging/RC). RC may not exist yet (a
        // future release-candidate desktop build), but is handled ahead of time.
        let bundle = (bundleID ?? "").lowercased()
        let base = "com.cmuxterm.app"
        if bundle == base { return "Stable" }
        if bundle.hasPrefix(base + ".") {
            let rest = bundle.dropFirst(base.count + 1)
            let channel = rest.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            switch channel {
            case "nightly": return "Nightly"
            case "rc": return "RC"
            case "staging": return "Staging"
            case "debug", "dev": return "DEV"
            default: return nil // unknown channel component — don't guess
            }
        }
        // A non-`com.cmuxterm.app` bundle that is clearly a dev build (e.g. the iOS
        // dev bundle `dev.cmux.*`).
        if bundle.hasPrefix("dev.cmux") { return "DEV" }
        return nil
    }
}
