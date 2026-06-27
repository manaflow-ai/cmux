public import SwiftUI
public import CmuxSidebar
import CmuxExtensionKit

/// The modal access-review sheet presented when the user reviews an extension's
/// pending sensitive access: the header (glyph, formatted title, bundle id), the
/// explanatory copy, the configuration row plus ``ExtensionPermissionSection``,
/// and the keep-limited / allow-requested-access buttons.
///
/// A pure presentation leaf driven by an immutable
/// ``CMUXSidebarExtensionEffectiveGrant`` value plus already-localized copy via
/// ``ExtensionAccessReviewSheetStrings``; it holds no app-target state. The
/// keep-limited and allow behaviors (which mutate the app's grant store and
/// dismiss the sheet) are passed in as closures and stay in the app target;
/// `String(localized:)` stays app-side. The configuration value is byte-identical
/// interpolation of the manifest id and minimum API version.
public struct ExtensionAccessReviewSheet: View {
    private let bundleIdentifier: String
    private let grant: CMUXSidebarExtensionEffectiveGrant
    private let strings: ExtensionAccessReviewSheetStrings
    private let onKeepLimited: () -> Void
    private let onAllow: () -> Void

    /// Creates the access-review sheet.
    /// - Parameters:
    ///   - bundleIdentifier: The reviewed extension's bundle identifier.
    ///   - grant: The effective grant whose requested scopes are reviewed.
    ///   - strings: App-resolved localized copy.
    ///   - onKeepLimited: Keeps the extension limited and dismisses the sheet.
    ///   - onAllow: Grants the requested access and dismisses the sheet.
    public init(
        bundleIdentifier: String,
        grant: CMUXSidebarExtensionEffectiveGrant,
        strings: ExtensionAccessReviewSheetStrings,
        onKeepLimited: @escaping () -> Void,
        onAllow: @escaping () -> Void
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.grant = grant
        self.strings = strings
        self.onKeepLimited = onKeepLimited
        self.onAllow = onAllow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 22, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.reviewTitle)
                    .font(.system(size: 15, weight: .semibold))
                    Text(bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(strings.reviewDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ExtensionDetailRow(
                    title: strings.manifestLabel,
                    value: "\(grant.manifest.id) · API \(grant.manifest.minimumAPIVersion.major).\(grant.manifest.minimumAPIVersion.minor)"
                )
                Divider()
                ExtensionPermissionSection(grant: grant)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(strings.keepLimited) {
                    onKeepLimited()
                }
                .keyboardShortcut(.cancelAction)
                Button(strings.allow) {
                    onAllow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
    }
}
