import CmuxFoundation
import SwiftUI

/// What isolates a Cloud machine, in one short paragraph with a link to the
/// full security page. Shown by the New Machine and Network sheets.
struct CloudSecurityExplainer: View {
    static let learnMoreURL = URL(string: "https://cmux.com/docs/cloud-security")!

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                localized: "cloud.security.explainer",
                defaultValue: "Each machine is its own microVM. You have root inside it. Model API keys stay at the network edge and never enter the machine. Outbound access follows the Network setting."
            ))
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(String(localized: "cloud.security.learnMore", defaultValue: "Learn more"), destination: Self.learnMoreURL)
                .cmuxFont(size: 11)
                .accessibilityIdentifier("CloudSecurityExplainer.learnMore")
        }
        .accessibilityIdentifier("CloudSecurityExplainer")
    }
}
