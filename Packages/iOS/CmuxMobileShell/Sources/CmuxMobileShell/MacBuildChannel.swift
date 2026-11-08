import Foundation

/// Derives user-facing build and app names for a Mac from its bundle id and
/// canonical app-instance tag. Live presence supplies both fields; a saved
/// pairing can still identify Stable, Nightly, RC, Staging, or a tagged DEV
/// build from the tag alone while offline.
public struct MacBuildChannel: Sendable {
    /// Create a build-channel labeler.
    public init() {}

    /// A label like `"DEV · my-tag"`, `"Nightly"`, `"RC"`, `"Staging"`, or
    /// `"Stable"`, or `nil` when there is nothing identifiable to show (an older
    /// host that reports neither a meaningful tag nor a known bundle id).
    public func label(bundleID: String?, tag: String?) -> String? {
        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulTag = trimmedTag?.isEmpty == false ? trimmedTag : nil
        let bundle = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let bundleLabel = bundleLabel(bundle) {
            guard let meaningfulTag else { return bundleLabel }
            let normalizedTag = meaningfulTag.lowercased()
            if normalizedTag == "default" || normalizedTag == canonicalTag(for: bundleLabel) {
                return bundleLabel
            }
            return "DEV · \(meaningfulTag)"
        }

        guard let meaningfulTag else { return nil }
        let normalizedTag = meaningfulTag.lowercased()
        if bundle.isEmpty {
            switch normalizedTag {
            case "default", "stable": return "Stable"
            case "nightly": return "Nightly"
            case "rc": return "RC"
            case "staging": return "Staging"
            case "dev": return "DEV"
            default: break
            }
        }
        if normalizedTag != "default" {
            return "DEV · \(meaningfulTag)"
        }
        return nil
    }

    /// The Mac app name to show beside a saved pairing, such as `"cmux"`,
    /// `"cmux Nightly"`, or `"cmux DEV my-tag"`.
    public func appDisplayName(bundleID: String?, tag: String?) -> String? {
        guard let label = label(bundleID: bundleID, tag: tag) else { return nil }
        switch label {
        case "Stable": return "cmux"
        case "Nightly": return "cmux Nightly"
        case "RC": return "cmux RC"
        case "Staging": return "cmux Staging"
        case "DEV": return "cmux DEV"
        default:
            let prefix = "DEV · "
            guard label.hasPrefix(prefix) else { return nil }
            return "cmux DEV \(label.dropFirst(prefix.count))"
        }
    }

    private func bundleLabel(_ bundle: String) -> String? {
        // The channel is the component RIGHT AFTER the base bundle id; a tagged
        // build appends a further `.slug` (e.g. `com.cmuxterm.app.nightly.my-tag`).
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
            default: return nil
            }
        }
        if bundle.hasPrefix("dev.cmux") { return "DEV" }
        return nil
    }

    private func canonicalTag(for label: String) -> String? {
        switch label {
        case "Stable": return "stable"
        case "Nightly": return "nightly"
        case "RC": return "rc"
        case "Staging": return "staging"
        case "DEV": return "dev"
        default: return nil
        }
    }
}
