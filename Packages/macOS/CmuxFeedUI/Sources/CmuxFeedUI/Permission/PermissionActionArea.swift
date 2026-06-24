public import SwiftUI

public import CMUXAgentLaunch

/// Renders the action area for a permission-request feed row.
///
/// When the request is pending it shows the parsed ``PermissionInputPreview``
/// code block plus the per-mode approval buttons the agent
/// (``WorkstreamSource``) offers, gated by ``PermissionModeCapabilities``. Once
/// resolved it collapses to a dimmed "Submitted" badge carrying the chosen
/// mode's label.
///
/// The view is a pure value taking only immutable props plus action closures,
/// so it never observes the live store and re-renders only when its inputs
/// change. Localized strings resolve against the app's main bundle (`bundle:
/// .main`) because the `feed.permission.*` / `feed.badge.*` keys live in the
/// app catalog, not the package bundle.
public struct PermissionActionArea: View {
    let toolName: String
    let toolInputJSON: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let onActionRow: () -> Void
    let onApprove: (WorkstreamPermissionMode) -> Void

    /// Creates the permission action area for a feed row.
    /// - Parameters:
    ///   - toolName: The agent tool name driving the request.
    ///   - toolInputJSON: The raw `tool_input` JSON string for the request.
    ///   - source: The agent that raised the request.
    ///   - status: The request's pending/resolved status.
    ///   - onActionRow: Invoked before an approval to mark the row as acted on.
    ///   - onApprove: Invoked with the chosen permission mode.
    public init(
        toolName: String,
        toolInputJSON: String,
        source: WorkstreamSource,
        status: WorkstreamStatus,
        onActionRow: @escaping () -> Void,
        onApprove: @escaping (WorkstreamPermissionMode) -> Void
    ) {
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.source = source
        self.status = status
        self.onActionRow = onActionRow
        self.onApprove = onApprove
    }

    private var permissionCapabilities: PermissionModeCapabilities {
        source.permissionModeCapabilities(toolInputJSON: toolInputJSON)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolLabel
            codeBlock
            if status.isPending {
                HStack(spacing: 6) {
                    FeedButton(label: String(localized: "feed.permission.deny", defaultValue: "Deny", bundle: .main),
                               kind: .dark, size: .medium, fullWidth: true) {
                        onActionRow()
                        onApprove(.deny)
                    }
                        .accessibilityIdentifier("FeedPermissionDenyButton")
                    if permissionCapabilities.supportsOnce {
                        FeedButton(label: String(localized: "feed.permission.once", defaultValue: "Allow Once", bundle: .main),
                                   kind: .light, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.once)
                        }
                            .accessibilityIdentifier("FeedPermissionAllowOnceButton")
                    }
                    if permissionCapabilities.supportsAlways {
                        FeedButton(label: String(localized: "feed.permission.always", defaultValue: "Always Allow", bundle: .main),
                                   kind: .primary, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.always)
                        }
                            .accessibilityIdentifier("FeedPermissionAlwaysAllowButton")
                    }
                    if permissionCapabilities.supportsAll {
                        FeedButton(label: String(localized: "feed.permission.all", defaultValue: "All tools", bundle: .main),
                                   kind: .primary, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.all)
                        }
                            .accessibilityIdentifier("FeedPermissionAllToolsButton")
                    }
                    if source.supportsBypassPermissions {
                        FeedButton(label: String(localized: "feed.permission.bypass", defaultValue: "Bypass", bundle: .main),
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
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted", bundle: .main)
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
