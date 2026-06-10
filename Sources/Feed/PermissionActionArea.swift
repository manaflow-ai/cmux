import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

struct PermissionActionArea: View {
    let toolName: String
    let toolInputJSON: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let onActionRow: () -> Void
    let onApprove: (WorkstreamPermissionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolLabel
            codeBlock
            if status.isPending {
                HStack(spacing: 6) {
                    FeedButton(label: String(localized: "feed.permission.deny", defaultValue: "Deny"),
                               kind: .dark, size: .medium, fullWidth: true) {
                        onActionRow()
                        onApprove(.deny)
                    }
                        .accessibilityIdentifier("FeedPermissionDenyButton")
                    if FeedPermissionActionPolicy.supportsOncePermissionMode(
                        source: source,
                        toolInputJSON: toolInputJSON
                    ) {
                        FeedButton(label: String(localized: "feed.permission.once", defaultValue: "Allow Once"),
                                   kind: .light, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.once)
                        }
                            .accessibilityIdentifier("FeedPermissionAllowOnceButton")
                    }
                    if FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                        source: source,
                        toolInputJSON: toolInputJSON
                    ) {
                        FeedButton(label: String(localized: "feed.permission.always", defaultValue: "Always Allow"),
                                   kind: .primary, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.always)
                        }
                            .accessibilityIdentifier("FeedPermissionAlwaysAllowButton")
                    }
                    if FeedPermissionActionPolicy.supportsAllPermissionMode(
                        source: source,
                        toolInputJSON: toolInputJSON
                    ) {
                        FeedButton(label: String(localized: "feed.permission.all", defaultValue: "All tools"),
                                   kind: .primary, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.all)
                        }
                            .accessibilityIdentifier("FeedPermissionAllToolsButton")
                    }
                    if FeedPermissionActionPolicy.supportsBypassPermissions(source: source) {
                        FeedButton(label: String(localized: "feed.permission.bypass", defaultValue: "Bypass"),
                                   kind: .destructive, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.bypass)
                        }
                            .accessibilityIdentifier("FeedPermissionBypassButton")
                    }
                }
            } else if let badge = submittedBadge {
                FeedButton(
                    label: badge,
                    leadingIcon: "checkmark",
                    kind: .success,
                    size: .medium,
                    fullWidth: true,
                    dimmed: true
                ) {}
            }
        }
    }

    private var submittedBadge: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        if case .permission(let mode) = decision {
            return "\(submitted) · \(mode.displayLabel)"
        }
        return submitted
    }

    private var toolLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
            Text(toolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
        }
    }

    private var codeBlock: some View {
        let preview = PermissionInputPreview(
            toolName: toolName,
            toolInputJSON: toolInputJSON
        )
        return VStack(alignment: .leading, spacing: 6) {
            if let primary = preview.primary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let sigil = preview.sigil {
                        Text(sigil)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    Text(primary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.95))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let secondary = preview.secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

/// Pulls a human-readable command + description out of an agent's
/// tool_input JSON. Handles Bash (`command` + `description`), Write /
/// Edit / Read (`file_path`), and falls back to the raw JSON.
private struct PermissionInputPreview {
    let sigil: String?
    let primary: String?
    let secondary: String?

    init(toolName: String, toolInputJSON: String) {
        let dict = (try? JSONSerialization.jsonObject(
            with: Data(toolInputJSON.utf8)
        )) as? [String: Any] ?? [:]

        switch toolName.lowercased() {
        case "bash":
            self.sigil = "$"
            self.primary = (dict["command"] as? String) ?? toolInputJSON
            self.secondary = (dict["description"] as? String)
        case "write", "edit", "multiedit":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            if toolName.lowercased() == "write" {
                let content = (dict["content"] as? String) ?? ""
                let preview = content.split(separator: "\n").first.map(String.init) ?? ""
                self.secondary = preview.isEmpty ? nil : preview
            } else {
                self.secondary = nil
            }
        case "read":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            self.secondary = nil
        default:
            self.sigil = nil
            self.primary = toolInputJSON == "{}" ? nil : toolInputJSON
            self.secondary = nil
        }
    }
}

extension WorkstreamPermissionMode {
    var displayLabel: String {
        switch self {
        case .once:
            return String(localized: "feed.permission.mode.once", defaultValue: "once")
        case .always:
            return String(localized: "feed.permission.mode.always", defaultValue: "always")
        case .all:
            return String(localized: "feed.permission.mode.all", defaultValue: "all tools")
        case .bypass:
            return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass")
        case .deny:
            return String(localized: "feed.permission.mode.deny", defaultValue: "denied")
        }
    }
}

