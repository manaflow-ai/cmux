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
        let summary = model.usageSummary ?? .init(totalTokens: 0, totalValue: 0, maximumTokens: 1)
        HStack(spacing: 12) {
            usageMetric(
                label: String(localized: "coderouter.sidebar.usage.tokens", defaultValue: "Tokens"),
                value: Self.compactNumber(summary.totalTokens)
            )
            usageMetric(
                label: String(localized: "coderouter.sidebar.usage.value", defaultValue: "API value"),
                value: Self.currency(summary.totalValue)
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
                        ProgressView(value: Double(max(0, machine.totals.totalTokens)), total: Double(summary.maximumTokens))
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
                    CoderouterAccountRow(
                        account: account,
                        onToggleClaude: { value, enabled in
                            startAction { try await model.setClaude(value, enabled: enabled) }
                        },
                        onRemove: { accountToRemove = $0 }
                    )
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


    func remove(_ account: CoderouterAccountsPanelModel.Account) {
        accountToRemove = nil
        startAction { try await model.remove(account) }
    }
}
