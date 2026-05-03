import SwiftUI

// MARK: - AI Usage Monitoring Settings Section
//
// Renders the "AI Usage Monitoring" and "Usage bar colors" blocks that
// appear in Settings. Presentation modifiers (.sheet / .confirmationDialog
// / .alert) live at the Settings view root; this struct only renders the
// two SettingsCard groups and toggles the bindings passed in from the
// parent.

struct ProviderAccountsSettingsSection: View {
    @ObservedObject var store: ProviderAccountStore
    @ObservedObject var controller: ProviderAccountsController
    @ObservedObject var colorSettings: ProviderUsageColorSettings

    @Binding var editorAccount: ProviderAccount?
    @Binding var editorProvider: UsageProvider?
    @Binding var accountToRemove: ProviderAccount?
    @Binding var showRemoveConfirmation: Bool

    private var uiProviders: [UsageProvider] { ProviderRegistry.ui }

    var body: some View {
        Group {
            SettingsSectionHeader(title: String(localized: "providers.accounts.section.title", defaultValue: "AI Usage Monitoring"))
                .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .providerAccounts))
                .accessibilityIdentifier("SettingsProviderAccountsSection")
            SettingsCard {
                accountsList
                addProfileRow
            }

            SettingsSectionHeader(title: String(localized: "providers.accounts.colors.section.title", defaultValue: "Usage bar colors"))
            SettingsCard {
                colorsContent
            }
        }
    }

    // MARK: - Accounts list

    @ViewBuilder
    private var accountsList: some View {
        // Only providers with at least one configured account; keeps the list
        // free of empty headers and dividers for providers the user hasn't set
        // up yet.
        let providersWithAccounts = uiProviders.compactMap { provider -> (UsageProvider, [ProviderAccount])? in
            let accounts = store.accounts.filter { $0.providerId == provider.id }
            return accounts.isEmpty ? nil : (provider, accounts)
        }
        // Accounts whose providerId no longer resolves to a registered UI
        // provider (registry churn, downgraded builds) must still be visible
        // and removable — otherwise their Keychain credentials become orphaned.
        let knownProviderIds = Set(uiProviders.map(\.id))
        let orphanAccounts = store.accounts.filter { !knownProviderIds.contains($0.providerId) }
        let sectionCount = providersWithAccounts.count + (orphanAccounts.isEmpty ? 0 : 1)

        ForEach(Array(providersWithAccounts.enumerated()), id: \.element.0.id) { providerIndex, entry in
            let (provider, providerAccounts) = entry
            if providerIndex > 0 {
                SettingsCardDivider()
            }
            if sectionCount > 1 {
                HStack {
                    Text(provider.displayName.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            ForEach(Array(providerAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 || sectionCount > 1 {
                    SettingsCardDivider()
                }
                accountRow(provider: provider, account: account)
            }
        }
        if !orphanAccounts.isEmpty {
            if !providersWithAccounts.isEmpty {
                SettingsCardDivider()
            }
            HStack {
                Text(String(localized: "providers.accounts.settings.unknownProvider", defaultValue: "UNKNOWN PROVIDER"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            ForEach(Array(orphanAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    SettingsCardDivider()
                }
                orphanAccountRow(account: account)
            }
        }
    }

    private func orphanAccountRow(account: ProviderAccount) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(String(
                    localized: "providers.accounts.settings.unknownProvider.subtitle",
                    defaultValue: "Provider: \(account.providerId)"
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(String(localized: "providers.accounts.remove.button", defaultValue: "Remove")) {
                accountToRemove = account
                showRemoveConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func accountRow(provider: UsageProvider, account: ProviderAccount) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .medium))
                // Show a live fetch error ahead of any cached snapshot so
                // expired credentials don't stay hidden behind a last-good
                // utilization row.
                if let error = controller.fetchErrors[account.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if let snapshot = controller.snapshots[account.id] {
                    Text(String(
                        localized: "providers.accounts.settings.summary",
                        defaultValue: "Session \(snapshot.session.utilization)% · Week \(snapshot.week.utilization)%"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(String(localized: "providers.accounts.edit.button", defaultValue: "Edit")) {
                editorAccount = store.accounts.first { $0.id == account.id }
                editorProvider = provider
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(String(localized: "providers.accounts.remove.button", defaultValue: "Remove")) {
                accountToRemove = account
                showRemoveConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var addProfileRow: some View {
        // Every persisted account — registered provider or orphan — renders a
        // row above this one, so the divider belongs whenever anything is on
        // screen regardless of provider registration.
        if !store.accounts.isEmpty {
            SettingsCardDivider()
        }

        HStack {
            if uiProviders.count > 1 {
                Menu(String(localized: "providers.accounts.add.button", defaultValue: "Add profile…")) {
                    ForEach(uiProviders, id: \.id) { p in
                        Button(String(format: String(localized: "providers.accounts.add.menu.label", defaultValue: "Add %@ profile…"), p.displayName)) {
                            editorAccount = nil
                            editorProvider = p
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let provider = uiProviders.first {
                Button(String(format: String(localized: "providers.accounts.add.menu.label", defaultValue: "Add %@ profile…"), provider.displayName)) {
                    editorAccount = nil
                    editorProvider = provider
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            let providersWithHelp = uiProviders.compactMap { provider -> (UsageProvider, URL)? in
                guard let url = provider.helpDocURL else { return nil }
                return (provider, url)
            }
            if providersWithHelp.count == 1, let first = providersWithHelp.first {
                Button {
                    NSWorkspace.shared.open(first.1)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text(String(localized: "providers.accounts.help.link", defaultValue: "Setup instructions"))
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
            } else if providersWithHelp.count > 1 {
                Menu {
                    ForEach(providersWithHelp, id: \.0.id) { entry in
                        Button(entry.0.displayName) {
                            NSWorkspace.shared.open(entry.1)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text(String(localized: "providers.accounts.help.link", defaultValue: "Setup instructions"))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Color settings

    private var lowColorBinding: Binding<Color> {
        Binding(
            get: { Color(usageHex: colorSettings.lowColorHex) ?? ProviderUsageColorSettings.defaultLowColor },
            set: { colorSettings.lowColorHex = $0.usageHexString }
        )
    }

    private var midColorBinding: Binding<Color> {
        Binding(
            get: { Color(usageHex: colorSettings.midColorHex) ?? ProviderUsageColorSettings.defaultMidColor },
            set: { colorSettings.midColorHex = $0.usageHexString }
        )
    }

    private var highColorBinding: Binding<Color> {
        Binding(
            get: { Color(usageHex: colorSettings.highColorHex) ?? ProviderUsageColorSettings.defaultHighColor },
            set: { colorSettings.highColorHex = $0.usageHexString }
        )
    }

    @ViewBuilder
    private var colorsContent: some View {
        let lowLabel = String(localized: "providers.accounts.colors.low", defaultValue: "Low")
        let midLabel = String(localized: "providers.accounts.colors.mid", defaultValue: "Mid")
        let highLabel = String(localized: "providers.accounts.colors.high", defaultValue: "High")

        SettingsCardRow(
            configurationReview: .settingsOnly,
            lowLabel
        ) {
            ColorPicker(lowLabel, selection: lowColorBinding, supportsOpacity: false)
                .labelsHidden()
        }

        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            midLabel
        ) {
            ColorPicker(midLabel, selection: midColorBinding, supportsOpacity: false)
                .labelsHidden()
        }

        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            highLabel
        ) {
            ColorPicker(highLabel, selection: highColorBinding, supportsOpacity: false)
                .labelsHidden()
        }

        SettingsCardDivider()

        let lowMidLabel = String(localized: "providers.accounts.colors.lowMidThreshold", defaultValue: "Low → Mid threshold (%)")
        SettingsCardRow(
            configurationReview: .settingsOnly,
            lowMidLabel
        ) {
            Stepper(
                value: Binding(
                    get: { colorSettings.lowMidThreshold },
                    set: { colorSettings.setThresholds(low: $0, high: colorSettings.midHighThreshold) }
                ),
                in: 1...(colorSettings.midHighThreshold - 1)
            ) {
                Text("\(colorSettings.lowMidThreshold)")
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            .accessibilityLabel(lowMidLabel)
        }

        SettingsCardDivider()

        let midHighLabel = String(localized: "providers.accounts.colors.midHighThreshold", defaultValue: "Mid → High threshold (%)")
        SettingsCardRow(
            configurationReview: .settingsOnly,
            midHighLabel
        ) {
            Stepper(
                value: Binding(
                    get: { colorSettings.midHighThreshold },
                    set: { colorSettings.setThresholds(low: colorSettings.lowMidThreshold, high: $0) }
                ),
                in: (colorSettings.lowMidThreshold + 1)...99
            ) {
                Text("\(colorSettings.midHighThreshold)")
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            .accessibilityLabel(midHighLabel)
        }

        SettingsCardDivider()

        let interpolateLabel = String(localized: "providers.accounts.colors.interpolate", defaultValue: "Interpolate between colors")
        SettingsCardRow(
            configurationReview: .settingsOnly,
            interpolateLabel
        ) {
            Toggle(interpolateLabel, isOn: Binding(
                get: { colorSettings.interpolate },
                set: { colorSettings.interpolate = $0 }
            ))
            .labelsHidden()
            .controlSize(.small)
        }

        SettingsCardDivider()

        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "providers.accounts.colors.preview", defaultValue: "Preview"))
                .font(.caption)
                .foregroundColor(.secondary)
            Canvas { ctx, size in
                for i in 0...100 {
                    let color = colorSettings.color(for: i)
                    let x = size.width * CGFloat(i) / 101
                    let w = size.width / 101
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(color))
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)

        SettingsCardDivider()

        HStack {
            Spacer()
            Button(String(localized: "providers.accounts.colors.reset", defaultValue: "Reset to defaults")) {
                colorSettings.resetToDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
