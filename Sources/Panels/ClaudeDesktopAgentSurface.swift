import AppKit
import Foundation
import SwiftUI

struct ClaudeDesktopAgentSurface: View {
    let panelID: UUID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor

    var body: some View {
        ForeignWindowSurface(
            surfaceID: panelID,
            launchConfiguration: launchConfiguration,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor
        )
    }

    private var launchConfiguration: ForeignWindowLaunchConfiguration {
        let fileManager = FileManager.default
        let profileDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/cmux",
                isDirectory: true
            )
            .appendingPathComponent(
                "external-apps/claude",
                isDirectory: true
            )
            .appendingPathComponent(
                panelID.uuidString.lowercased(),
                isDirectory: true
            )

        let preferredApplicationURL = ProcessInfo.processInfo.environment[
            "CMUX_CLAUDE_DESKTOP_APP_PATH"
        ].flatMap { rawPath -> URL? in
            let trimmed = rawPath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed)
        }

        return ForeignWindowLaunchConfiguration(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            preferredApplicationURL: preferredApplicationURL,
            fallbackApplicationURLs: [
                URL(fileURLWithPath: "/Applications/Claude.app"),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Applications/Claude.app",
                        isDirectory: true
                    )
            ],
            arguments: [
                "--user-data-dir=\(profileDirectoryURL.path)"
            ],
            environment: [:],
            directoriesToCreate: [profileDirectoryURL]
        )
    }
}
