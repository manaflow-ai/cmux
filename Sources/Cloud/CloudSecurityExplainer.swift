import CmuxFoundation
import SwiftUI

/// A small info button next to the Network control that explains what
/// isolates a Cloud machine, with a link to the full security page. The
/// paragraph lives in a popover so the New Machine and Network sheets stay
/// compact. The popover is its own window, so its wrapping text never feeds
/// back into the sheet's `preferredContentSize` while the sheet opens.
struct CloudSecurityExplainer: View {
    static let learnMoreURL = URL(string: "https://cmux.com/docs/cloud-security")!

    @State private var showsDetails = false

    private var title: String {
        String(localized: "cloud.security.info", defaultValue: "How machines are isolated")
    }

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("CloudSecurityExplainer")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(
                    localized: "cloud.security.explainer",
                    defaultValue: "Each machine is its own microVM. You have root inside it. Model API keys stay at the network edge and never enter the machine. Outbound access follows the Network setting."
                ))
                .cmuxFont(size: 12)
                .fixedSize(horizontal: false, vertical: true)
                Link(String(localized: "cloud.security.learnMore", defaultValue: "Learn more"), destination: Self.learnMoreURL)
                    .cmuxFont(size: 12)
                    .accessibilityIdentifier("CloudSecurityExplainer.learnMore")
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}
