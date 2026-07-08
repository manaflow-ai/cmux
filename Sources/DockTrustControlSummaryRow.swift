import Foundation
import SwiftUI

struct DockTrustControlSummaryRow: View {
    let summary: DockTrustControlSummary

    var body: some View {
        let rows = detailRows
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows.indices, id: \.self) { index in
                    Text(rows[index])
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private var detailRows: [String] {
        switch summary.detail {
        case .command(let command, let workingDirectory, let environment):
            return [command, workingDirectoryLine(workingDirectory)] + environmentRows(environment)
        case .loginShell(let workingDirectory, let environment):
            return [
                String(localized: "dock.trust.control.loginShell", defaultValue: "Login shell"),
                workingDirectoryLine(workingDirectory)
            ] + environmentRows(environment)
        case .browser(let url, let profileDisplayName, let profileIsDefault, let profileID):
            let profileName = profileIsDefault
                ? String(localized: "dock.trust.control.defaultBrowserProfile", defaultValue: "Default browser profile")
                : profileDisplayName
            let profileLine = String(
                format: String(localized: "dock.trust.control.browserProfile", defaultValue: "Profile: %@"),
                profileName
            )
            guard !profileIsDefault, !profileID.isEmpty else {
                return [url, profileLine]
            }
            let profileIDLine = String(
                format: String(localized: "dock.trust.control.browserProfileID", defaultValue: "Profile ID: %@"),
                profileID
            )
            return [url, profileLine, profileIDLine]
        }
    }

    private func workingDirectoryLine(_ workingDirectory: String) -> String {
        String(
            format: String(localized: "dock.trust.control.workingDirectory", defaultValue: "cwd: %@"),
            workingDirectory
        )
    }

    private func environmentRows(_ environment: [String: String]) -> [String] {
        environment.sorted { $0.key < $1.key }.map { entry in
            String(
                format: String(localized: "dock.trust.control.environment", defaultValue: "env: %@"),
                "\(entry.key)=\(entry.value)"
            )
        }
    }
}
