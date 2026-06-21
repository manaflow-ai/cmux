/// Derives a short, user-facing build-channel label for a Mac from what its
/// presence heartbeat reports — its bundle id and dev tag — so the Computers
/// screen can show whether a host is a DEV build (and which tag), Nightly, RC,
/// Staging, or Stable.
///
/// The dev tag is the primary DEV signal: a tagged `reload.sh` build sets
/// `CMUX_TAG`, so any non-`"default"` tag means a DEV build and the tag is the
/// thing worth showing. Otherwise the channel comes from the bundle-id suffix.
public enum MacBuildChannel {
    /// A label like `"DEV · my-tag"`, `"Nightly"`, `"RC"`, `"Staging"`, or
    /// `"Stable"`, or `nil` when there is nothing identifiable to show (an older
    /// host that reports neither a meaningful tag nor a known bundle id).
    public static func label(bundleID: String?, tag: String?) -> String? {
        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let devTag = (trimmedTag?.isEmpty == false && trimmedTag != "default") ? trimmedTag : nil
        if let devTag {
            return "DEV · \(devTag)"
        }
        let bundle = (bundleID ?? "").lowercased()
        if bundle.hasPrefix("dev.cmux") || bundle.contains(".dev") {
            return "DEV"
        }
        if bundle.hasSuffix(".nightly") { return "Nightly" }
        if bundle.hasSuffix(".rc") { return "RC" }
        if bundle.hasSuffix(".staging") { return "Staging" }
        if bundle == "com.cmuxterm.app" { return "Stable" }
        return nil
    }
}
