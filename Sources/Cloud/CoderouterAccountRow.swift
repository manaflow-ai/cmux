import CmuxFoundation
import SwiftUI

struct CoderouterAccountRow: View {
    let account: CoderouterAccountsPanelModel.Account
    let onToggleClaude: (CoderouterAccountsPanelModel.ClaudeAccount, Bool) -> Void
    let onRemove: (CoderouterAccountsPanelModel.Account) -> Void

    var body: some View {
        switch account {
        case .claude(let value): claudeRow(value)
        case .native(let value): nativeRow(value)
        case .shared(let value): sharedRow(value)
        }
    }

    func claudeRow(_ account: CoderouterAccountsPanelModel.ClaudeAccount) -> some View {
        let cooling = account.cooldownUntil.map { $0 > Date() } ?? false
        let disabled = account.state == "disabled"
        return accountRowChrome(
            icon: "sparkles",
            provider: CoderouterAccountsPanel.claudeProviderLabel(account.kind),
            label: account.label,
            detail: [account.identifier, account.region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            status: disabled
                ? String(localized: "coderouter.sidebar.status.disabled", defaultValue: "Disabled")
                : cooling
                    ? String(localized: "coderouter.sidebar.status.cooling", defaultValue: "Cooling down")
                    : String(localized: "coderouter.sidebar.status.active", defaultValue: "Active"),
            statusColor: disabled || cooling ? .orange : .green,
            dimmed: disabled,
            menu: {
                Button(disabled
                       ? String(localized: "coderouter.sidebar.enable", defaultValue: "Enable")
                       : String(localized: "coderouter.sidebar.disable", defaultValue: "Disable")) {
                    onToggleClaude(account, disabled)
                }
                Divider()
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    onRemove(.claude(account))
                }
            }
        )
    }

    func sharedRow(_ account: CoderouterAccountsPanelModel.SharedAccount) -> some View {
        let healthy = account.healthOK == true
        return accountRowChrome(
            icon: "person.crop.circle",
            provider: CoderouterAccountsPanel.sharedProviderLabel(account.kind),
            label: account.label,
            detail: account.createdAt.map { CoderouterAccountsPanel.createdLabel($0) } ?? "",
            status: account.healthOK == nil
                ? String(localized: "coderouter.sidebar.status.unknown", defaultValue: "Status unknown")
                : healthy
                    ? String(localized: "coderouter.sidebar.status.healthy", defaultValue: "Healthy")
                    : String(localized: "coderouter.sidebar.status.unhealthy", defaultValue: "Needs attention"),
            statusColor: account.healthOK == nil ? .secondary : (healthy ? .green : .orange),
            dimmed: account.healthOK == false,
            menu: {
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    onRemove(.shared(account))
                }
            }
        )
    }

    func nativeRow(_ account: CoderouterAccountsPanelModel.NativeAccount) -> some View {
        let cooling = account.cooldownUntil.map { $0 > Date() } ?? false
        let broken = account.state == "broken" || account.state == "expired"
        let status = broken
            ? String(localized: "coderouter.sidebar.status.needsRepair", defaultValue: "Needs repair")
            : cooling
                ? String(localized: "coderouter.sidebar.status.cooling", defaultValue: "Cooling down")
                : String(localized: "coderouter.sidebar.status.active", defaultValue: "Active")
        return accountRowChrome(
            icon: "key.fill",
            provider: CoderouterAccountsPanel.nativeProviderLabel(account.provider),
            label: account.label,
            detail: [account.providerAccountID, account.activeSessions > 0 ? CoderouterAccountsPanel.sessionLabel(account.activeSessions) : nil]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            status: status,
            statusColor: broken || cooling ? .orange : .green,
            dimmed: broken,
            menu: {
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    onRemove(.native(account))
                }
            }
        )
    }

    func accountRowChrome<Menu: View>(
        icon: String,
        provider: String,
        label: String,
        detail: String,
        status: String,
        statusColor: Color,
        dimmed: Bool,
        @ViewBuilder menu: () -> Menu
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dimmed ? .tertiary : .secondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(provider)
                        .cmuxFont(size: 10, weight: .medium)
                        .foregroundStyle(dimmed ? .secondary : .primary)
                        .lineLimit(1)
                    if !label.isEmpty {
                        Text(label)
                            .cmuxFont(size: 10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .cmuxFont(size: 9, design: .monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                Text(status)
                    .cmuxFont(size: 9)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "coderouter.sidebar.accountActions", defaultValue: "Account actions"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.75 : 1)
        .contentShape(Rectangle())
    }
}
