import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct ExitPlanPlanFileView: View {
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.text")
                .cmuxFont(size: 10, weight: .medium)
                .foregroundColor(.secondary)
            Text(String(localized: "feed.exitplan.planFile", defaultValue: "Plan file"))
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundColor(.secondary)
            Text((path as NSString).lastPathComponent)
                .cmuxFont(size: 10, design: .monospaced)
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

