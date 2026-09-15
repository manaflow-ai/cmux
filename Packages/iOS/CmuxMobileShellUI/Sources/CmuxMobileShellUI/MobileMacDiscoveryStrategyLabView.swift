#if os(iOS) && DEBUG
import CmuxMobileShellModel
import SwiftUI

/// Local route-acceptance prototype, separate from first-pair discovery preferences.
struct MobileMacDiscoveryStrategyLabView: View {
    @AppStorage(MobileMacDiscoveryStrategyStore.strategyKey)
    private var rawStrategy = MobileMacDiscoveryStrategy.automatic.rawValue
    @State private var layout = MobileTailscaleSuggestionView.Layout.inline
    @State private var tailscaleOnly = true
    @State private var acceptedIDs: Set<String> = [MobileTailscaleLabRoute.saved.id]
    @State private var reviewingRoute: MobileTailscaleLabRoute?

    private var suggestions: [MobileTailscaleLabRoute] {
        MobileTailscaleLabRoute.samples.filter { !acceptedIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "mobile.pathDiscoveryLab.layout", defaultValue: "Suggestion layout", bundle: .module), selection: $layout) {
                    ForEach(MobileTailscaleSuggestionView.Layout.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("MobileTailscaleLabLayout")
                Picker(String(localized: "mobile.pathDiscoveryLab.mode", defaultValue: "Connection mode", bundle: .module), selection: $tailscaleOnly) {
                    Text(String(localized: "mobile.pathDiscoveryLab.automatic", defaultValue: "Automatic", bundle: .module)).tag(false)
                    Text(String(localized: "mobile.pathDiscoveryLab.tailscaleOnly", defaultValue: "Tailscale Only", bundle: .module)).tag(true)
                }
                .accessibilityIdentifier("MobileTailscaleLabMode")
            } header: {
                Text(String(localized: "mobile.pathDiscoveryLab.preview", defaultValue: "Computer Details preview", bundle: .module))
            } footer: {
                Text(String(localized: "mobile.pathDiscoveryLab.sample", defaultValue: "Sample routes for trying the UI. Changes apply only to this preview.", bundle: .module))
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "mobile.pathDiscoveryLab.iroh", defaultValue: "Iroh", bundle: .module), systemImage: "network")
                    Text(tailscaleOnly ? String(localized: "mobile.pathDiscoveryLab.irohPaused", defaultValue: "Saved. Unavailable in Tailscale Only mode.", bundle: .module) : String(localized: "mobile.pathDiscoveryLab.irohReady", defaultValue: "Available in Automatic mode.", bundle: .module))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("MobileTailscaleSavedRoute-iroh")
                ForEach(MobileTailscaleLabRoute.samples.filter { acceptedIDs.contains($0.id) }) { route in
                    MobileTailscaleRouteSummaryView(route: route)
                        .accessibilityIdentifier("MobileTailscaleSavedRoute-\(route.id)")
                        .swipeActions {
                            Button(String(localized: "mobile.pathDiscoveryLab.remove", defaultValue: "Remove route", bundle: .module), role: .destructive) {
                                acceptedIDs.remove(route.id)
                            }
                        }
                }
            } header: {
                Text(String(localized: "mobile.pathDiscoveryLab.routes", defaultValue: "Routes", bundle: .module))
            } footer: {
                Text(String(localized: "mobile.pathDiscoveryLab.routesFooter", defaultValue: "Connection mode determines which saved routes can be used.", bundle: .module))
            }

            if tailscaleOnly {
                Section {
                    if suggestions.isEmpty {
                        Label(String(localized: "mobile.pathDiscoveryLab.allAdded", defaultValue: "All suggestions added to routes", bundle: .module), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("MobileTailscaleSuggestionsEmpty")
                    }
                    ForEach(suggestions) { route in
                        MobileTailscaleSuggestionView(route: route, layout: layout) {
                            if layout == .review {
                                reviewingRoute = route
                            } else {
                                accept(route)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "mobile.pathDiscoveryLab.suggestions", defaultValue: "Suggested Tailscale routes", bundle: .module))
                } footer: {
                    Text(String(localized: "mobile.pathDiscoveryLab.suggestionsFooter", defaultValue: "Suggestions stay unused until you add them. IPv4 and IPv6 belong to one route.", bundle: .module))
                }
            }

            Section {
                Button(String(localized: "mobile.pathDiscoveryLab.reset", defaultValue: "Reset sample routes", bundle: .module)) {
                    acceptedIDs = [MobileTailscaleLabRoute.saved.id]
                    reviewingRoute = nil
                }
                .accessibilityIdentifier("MobileTailscaleLabReset")
            }

            Section {
                Picker(String(localized: "mobile.pathDiscoveryLab.strategy", defaultValue: "Discovery strategy", bundle: .module), selection: $rawStrategy) {
                    ForEach(MobileMacDiscoveryStrategy.allCases) { option in
                        Text(discoveryTitle(option)).tag(option.rawValue)
                    }
                }
            } header: {
                Text(String(localized: "mobile.pathDiscoveryLab.firstPair", defaultValue: "Live first-pair discovery", bundle: .module))
            } footer: {
                Text(String(localized: "mobile.pathDiscoveryLab.discoveryFooter", defaultValue: "Separate from this preview. The next Computers refresh uses this strategy. QR / Manual skips live discovery.", bundle: .module))
            }
        }
        .navigationTitle(String(localized: "mobile.pathDiscoveryLab.title", defaultValue: "Path Discovery Lab", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileMacDiscoveryStrategyLab")
        .sheet(item: $reviewingRoute) { route in
            NavigationStack {
                Form {
                    Section {
                        MobileTailscaleRouteSummaryView(route: route, showsAddresses: true)
                    } footer: {
                        Text(String(localized: "mobile.pathDiscoveryLab.acceptFooter", defaultValue: "Add this Tailscale route and both its addresses alongside your saved routes.", bundle: .module))
                    }
                    Section {
                        Button(String(localized: "mobile.pathDiscoveryLab.add", defaultValue: "Add to routes", bundle: .module)) {
                            accept(route)
                            reviewingRoute = nil
                        }
                        .accessibilityIdentifier("MobileTailscaleConfirmAdd-\(route.id)")
                    }
                }
                .navigationTitle(String(localized: "mobile.pathDiscoveryLab.review", defaultValue: "Review route", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "mobile.pathDiscoveryLab.cancel", defaultValue: "Cancel", bundle: .module), role: .cancel) {
                            reviewingRoute = nil
                        }
                        .accessibilityIdentifier("MobileTailscaleCancelAdd")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Every layout accepts the same route identity, including all its addresses.
    private func accept(_ route: MobileTailscaleLabRoute) {
        acceptedIDs.insert(route.id)
    }

    private func discoveryTitle(_ strategy: MobileMacDiscoveryStrategy) -> String {
        switch strategy {
        case .automatic: String(localized: "mobile.pathDiscoveryLab.automatic", defaultValue: "Automatic", bundle: .module)
        case .tailscale: String(localized: "mobile.pathDiscoveryLab.tailscaleOnly", defaultValue: "Tailscale Only", bundle: .module)
        case .relay: String(localized: "mobile.pathDiscoveryLab.relay", defaultValue: "Relay", bundle: .module)
        case .qr: String(localized: "mobile.pathDiscoveryLab.qr", defaultValue: "QR / Manual", bundle: .module)
        }
    }
}
#endif
