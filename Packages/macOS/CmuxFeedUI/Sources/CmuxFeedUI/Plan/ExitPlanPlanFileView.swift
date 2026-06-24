public import SwiftUI

/// Single-line "Plan file: <name>" row showing the last path component of an
/// ExitPlanMode plan file, with the full path in a hover help tooltip.
public struct ExitPlanPlanFileView: View {
    let path: String

    /// Creates the plan-file row view.
    /// - Parameter path: Full path to the ExitPlanMode plan file.
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
