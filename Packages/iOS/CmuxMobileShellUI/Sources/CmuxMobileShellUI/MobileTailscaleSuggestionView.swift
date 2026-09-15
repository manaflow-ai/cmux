#if os(iOS) && DEBUG
import SwiftUI

struct MobileTailscaleSuggestionView: View {
    enum Layout: String, CaseIterable, Identifiable {
        case inline
        case details
        case review

        var id: String { rawValue }
        var title: String {
            switch self {
            case .inline: String(localized: "mobile.pathDiscoveryLab.inline", defaultValue: "Inline Add", bundle: .module)
            case .details: String(localized: "mobile.pathDiscoveryLab.details", defaultValue: "Expandable addresses", bundle: .module)
            case .review: String(localized: "mobile.pathDiscoveryLab.reviewFirst", defaultValue: "Review before adding", bundle: .module)
            }
        }
    }

    let route: MobileTailscaleLabRoute
    let layout: Layout
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MobileTailscaleRouteSummaryView(route: route, showsAddresses: layout == .inline)
            if layout == .details {
                DisclosureGroup(String(localized: "mobile.pathDiscoveryLab.addresses", defaultValue: "Show addresses", bundle: .module)) {
                    ForEach(route.addresses, id: \.self) { address in
                        Text(verbatim: address)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("MobileTailscaleShowAddresses-\(route.id)")
            }
            Button(action: onAccept) {
                Text(layout == .review ? String(localized: "mobile.pathDiscoveryLab.review", defaultValue: "Review route", bundle: .module) : String(localized: "mobile.pathDiscoveryLab.add", defaultValue: "Add to routes", bundle: .module))
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileTailscaleAddRoute-\(route.id)")
        }
        .accessibilityIdentifier("MobileTailscaleSuggestion-\(route.id)")
    }
}
#endif
