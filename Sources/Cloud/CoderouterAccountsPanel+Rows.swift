import CmuxCloud
import CmuxFoundation
import SwiftUI

extension CoderouterAccountsPanel {
    @ViewBuilder
    var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "coderouter.sidebar.usage.title", defaultValue: "Usage"))
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let usage = model.usage, usage.kind == .ready {
                    Text(Self.periodLabel(usage.periodDays))
                        .cmuxFont(size: 10, design: .monospaced)
                        .foregroundStyle(.tertiary)
                }
            }
            if model.failedSources.contains(.usage) {
                Text(String(localized: "coderouter.sidebar.usage.unavailable", defaultValue: "Usage is temporarily unavailable."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
            } else if let usage = model.usage, usage.kind == .ready {
                usageContent(usage)
            } else if model.state == .loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(String(localized: "coderouter.sidebar.usage.empty", defaultValue: "No CodeRouter usage yet."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
        .accessibilityIdentifier("CoderouterUsage")
    }

    @ViewBuilder
    func usageContent(_ usage: TeamMachineUsage) -> some View {
        let machines = usage.machines
        let totalTokens = machines.reduce(0) { $0 + $1.totals.totalTokens }
        let totalValue = machines.reduce(0.0) { $0 + $1.totals.apiEquivalentUsd }
        let maximum = max(1, machines.map { $0.totals.totalTokens }.max() ?? 0)
        HStack(spacing: 12) {
            usageMetric(
                label: String(localized: "coderouter.sidebar.usage.tokens", defaultValue: "Tokens"),
                value: Self.compactNumber(totalTokens)
            )
            usageMetric(
                label: String(localized: "coderouter.sidebar.usage.value", defaultValue: "API value"),
                value: Self.currency(totalValue)
            )
            Spacer(minLength: 0)
        }
        if machines.isEmpty {
            Text(String(localized: "coderouter.sidebar.usage.noMachines", defaultValue: "No Cloud machines have routed traffic in this period."))
                .cmuxFont(size: 10)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(machines, id: \.vmID) { machine in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(machine.displayName ?? machine.vmID)
                                .cmuxFont(size: 10)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Self.compactNumber(machine.totals.totalTokens))
                                .cmuxFont(size: 10, design: .monospaced, monospacedDigit: true)
                                .foregroundStyle(.tertiary)
                        }
                        ProgressView(value: Double(max(0, machine.totals.totalTokens)), total: Double(maximum))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(.accentColor)
                            .accessibilityLabel(String(
                                format: String(localized: "coderouter.sidebar.usage.machineLabel", defaultValue: "%@ usage"),
                                machine.displayName ?? machine.vmID
                            ))
                    }
                }
            }
        }
    }

    func usageMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .cmuxFont(size: 9)
                .foregroundStyle(.tertiary)
            Text(value)
                .cmuxFont(size: 12, weight: .medium, design: .monospaced, monospacedDigit: true)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    var accountsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "coderouter.sidebar.accounts", defaultValue: "Accounts"))
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.state == .loading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 5)
            if !model.failedSources.isEmpty, model.state == .failed || !model.accounts.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(String(localized: "coderouter.sidebar.partialError", defaultValue: "Some CodeRouter data could not be loaded."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "coderouter.sidebar.retry", defaultValue: "Retry")) {
                        model.refresh()
                    }
                    .buttonStyle(.link)
                }
                .cmuxFont(size: 10)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            }
            if model.accounts.isEmpty {
                emptyAccounts
            } else {
                ForEach(model.accounts) { account in
                    accountRow(account)
                }
            }
            if !ManagedAICredentialUploadPolicy.isEnabled {
                Text(ManagedAICredentialUploadPolicy.disabledMessage)
                    .cmuxFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)
            }
        }
        .accessibilityIdentifier("CoderouterAccounts")
    }

    var emptyAccounts: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.state == .loading
                 ? String(localized: "coderouter.sidebar.loading", defaultValue: "Loading accounts…")
                 : String(localized: "coderouter.sidebar.empty", defaultValue: "No accounts configured for this team."))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
            Text(String(localized: "coderouter.sidebar.emptyHint", defaultValue: "Add a Claude credential or upload a local AI account to route requests."))
                .cmuxFont(size: 10)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func accountRow(_ account: CoderouterAccountsPanelModel.Account) -> some View {
        switch account {
        case .claude(let value):
            claudeRow(value)
        case .native(let value):
            nativeRow(value)
        case .shared(let value):
            sharedRow(value)
        }
    }

    func claudeRow(_ account: CoderouterAccountsPanelModel.ClaudeAccount) -> some View {
        let cooling = account.cooldownUntil.map { $0 > Date() } ?? false
        let disabled = account.state == "disabled"
        return accountRowChrome(
            icon: "sparkles",
            provider: Self.claudeProviderLabel(account.kind),
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
                    Task { @MainActor in
                        do {
                            try await model.setClaude(account, enabled: disabled)
                        } catch {
                            operationError = Self.userMessage(error)
                        }
                    }
                }
                Divider()
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    accountToRemove = .claude(account)
                }
            }
        )
    }

    func sharedRow(_ account: CoderouterAccountsPanelModel.SharedAccount) -> some View {
        let healthy = account.healthOK == true
        return accountRowChrome(
            icon: "person.crop.circle",
            provider: Self.sharedProviderLabel(account.kind),
            label: account.label,
            detail: account.createdAt.map { Self.createdLabel($0) } ?? "",
            status: account.healthOK == nil
                ? String(localized: "coderouter.sidebar.status.unknown", defaultValue: "Status unknown")
                : healthy
                    ? String(localized: "coderouter.sidebar.status.healthy", defaultValue: "Healthy")
                    : String(localized: "coderouter.sidebar.status.unhealthy", defaultValue: "Needs attention"),
            statusColor: account.healthOK == nil ? .secondary : (healthy ? .green : .orange),
            dimmed: account.healthOK == false,
            menu: {
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    accountToRemove = .shared(account)
                }
            }
        )
        .help(account.healthMessage ?? "")
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
            provider: Self.nativeProviderLabel(account.provider),
            label: account.label,
            detail: [account.providerAccountID, account.activeSessions > 0 ? Self.sessionLabel(account.activeSessions) : nil]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            status: status,
            statusColor: broken || cooling ? .orange : .green,
            dimmed: broken,
            menu: {
                Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                    accountToRemove = .native(account)
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

    func remove(_ account: CoderouterAccountsPanelModel.Account) {
        accountToRemove = nil
        Task { @MainActor in
            do {
                try await model.remove(account)
            } catch {
                operationError = Self.userMessage(error)
            }
        }
    }
}
