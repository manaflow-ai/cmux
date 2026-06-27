public import CMUXAgentLaunch
public import SwiftUI

/// The interactive action area for a permission-request feed item. It renders
/// the requesting tool's name and a code-block preview of the tool input, and
/// (while the item is pending) the Deny / Allow Once / Always Allow / All tools
/// / Bypass approval buttons that `FeedPermissionActionPolicy` says the current
/// source + tool-input support; once resolved it shows the submitted badge.
///
/// The view takes only value snapshots plus closures so it can live below the
/// Feed's list snapshot boundary. The `feed.permission.*`/`feed.badge.*`
/// localization keys resolve against the app's main bundle (`bundle: .main`) so
/// the app-side `.xcstrings` catalog and its non-English translations keep
/// working from the package.
public struct PermissionActionArea: View {
    let toolName: String
    let toolInputJSON: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let onActionRow: () -> Void
    let onApprove: (WorkstreamPermissionMode) -> Void

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
                    if FeedPermissionActionPolicy.supportsOncePermissionMode(
                        source: source,
                        toolInputJSON: toolInputJSON
                    ) {
                        FeedButton(label: String(localized: "feed.permission.once", defaultValue: "Allow Once", bundle: .main),
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
                        FeedButton(label: String(localized: "feed.permission.always", defaultValue: "Always Allow", bundle: .main),
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
                        FeedButton(label: String(localized: "feed.permission.all", defaultValue: "All tools", bundle: .main),
                                   kind: .primary, size: .medium, fullWidth: true) {
                            onActionRow()
                            onApprove(.all)
                        }
                            .accessibilityIdentifier("FeedPermissionAllToolsButton")
                    }
                    if FeedPermissionActionPolicy.supportsBypassPermissions(source: source) {
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
