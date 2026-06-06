import CmuxSettings
import SwiftUI

/// **Mobile** section — Mac-side controls for pairing and syncing with
/// cmux on iOS.
@MainActor
public struct MobileSection: View {
    @State private var iOSPairingHost: DefaultsValueModel<Bool>
    private let hostActions: SettingsHostActions

    /// Creates a Mobile settings section bound to the supplied settings stores.
    ///
    /// - Parameters:
    ///   - defaultsStore: The user-defaults-backed settings store.
    ///   - catalog: The settings catalog defining the mobile keys.
    ///   - hostActions: Host callbacks for actions the package can't perform
    ///     itself, such as opening the iOS pairing window.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        _iOSPairingHost = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingHost))
        self.hostActions = hostActions
    }

    /// The Mobile settings section content.
    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.mobile", defaultValue: "Mobile"), section: .mobile)
            SettingsCard {
                pairDeviceRow
                SettingsCardDivider()
                iOSPairingHostRow
            }
        }
    }

    @ViewBuilder
    private var pairDeviceRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:mobile:pairDevice",
            String(localized: "settings.mobile.pairDevice", defaultValue: "Pair a Device"),
            subtitle: String(localized: "settings.mobile.pairDevice.subtitle", defaultValue: "Show a QR code to pair your iPhone or iPad with this Mac.")
        ) {
            Button(String(localized: "settings.mobile.pairDevice.button", defaultValue: "Pair…")) {
                hostActions.openMobilePairingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsMobilePairDeviceButton")
        }
    }

    @ViewBuilder
    private var iOSPairingHostRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingHost",
            String(localized: "settings.mobile.iOSPairingHost", defaultValue: "iOS Pairing"),
            subtitle: iOSPairingHost.current
                ? String(localized: "settings.mobile.iOSPairingHost.subtitleOn", defaultValue: "Allows the iOS app to discover and sync with this Mac on your local network.")
                : String(localized: "settings.mobile.iOSPairingHost.subtitleOff", defaultValue: "Keeps the Mac-side iOS pairing listener off until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { iOSPairingHost.current }, set: { iOSPairingHost.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMobileIOSPairingHostToggle")
        }
    }
}
