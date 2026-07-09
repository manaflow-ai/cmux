import Foundation
public import SwiftUI

/// A single row identifying the plan file an agent wrote during plan mode,
/// showing the file's last path component with the full path as a tooltip.
///
/// The `feed.exitplan.*` localization key is resolved against the app's main
/// bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and its
/// non-English translations keep working from the package.
public struct ExitPlanPlanFileView: View {
    let path: String

    public init(path: String) {
        self.path = path
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(String(localized: "feed.exitplan.planFile", defaultValue: "Plan file", bundle: .main))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}
