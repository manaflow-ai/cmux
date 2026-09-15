#if os(iOS) && DEBUG
import SwiftUI

struct MobileTailscaleRouteSummaryView: View {
    let route: MobileTailscaleLabRoute
    var showsAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "mobile.pathDiscoveryLab.tailscale", defaultValue: "Tailscale", bundle: .module), systemImage: "point.3.connected.trianglepath.dotted")
            Text(verbatim: route.name)
                .font(.subheadline)
            Text(String(localized: "mobile.pathDiscoveryLab.families", defaultValue: "IPv4 + IPv6 · One route", bundle: .module))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if showsAddresses {
                ForEach(route.addresses, id: \.self) { address in
                    Text(verbatim: address)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
