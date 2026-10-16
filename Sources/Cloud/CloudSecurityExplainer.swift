import CmuxFoundation
import SwiftUI

/// A small info button next to the Network control that explains what
/// isolates a Cloud machine, with a link to the full security page.
struct CloudSecurityExplainer: View {
    static let learnMoreURL = URL(string: "https://cmux.com/docs/cloud-security")!

    var body: some View {
        CloudInfoPopoverButton(
            title: String(localized: "cloud.security.info", defaultValue: "How machines are isolated"),
            text: String(
                localized: "cloud.security.explainer",
                defaultValue: "Each machine is its own microVM. You have root inside it. Model API keys stay at the network edge and never enter the machine. Outbound access follows the Network setting."
            ),
            learnMoreURL: Self.learnMoreURL,
            accessibilityIdentifier: "CloudSecurityExplainer"
        )
    }
}

/// The info button next to the New Machine sheet's Agents row: what "Keep
/// coding agents up to date" does, with a link to the Machines docs section.
/// The same text is the tooltip of the machine menu's "Keep Agents Up to Date".
struct CloudAgentUpdatesExplainer: View {
    static let learnMoreURL = URL(string: "https://cmux.com/docs/cloud/machines#agent-updates")!

    static var title: String {
        String(localized: "cloud.agentUpdates.info", defaultValue: "How agents stay up to date")
    }

    static var text: String {
        String(
            localized: "cloud.agentUpdates.explainer",
            defaultValue: "When you connect, at most once a day, the machine updates Claude Code, Codex, OpenCode, Pi, and agent-browser from each tool's official GitHub release. A release installs only after it has been public for 3 days, and never as a downgrade."
        )
    }

    var body: some View {
        CloudInfoPopoverButton(
            title: Self.title,
            text: Self.text,
            learnMoreURL: Self.learnMoreURL,
            accessibilityIdentifier: "CloudAgentUpdatesExplainer"
        )
    }
}

/// An ⓘ button whose paragraph and "Learn more" link live in a popover, so
/// the New Machine and Network sheets stay compact. The popover is its own
/// window, so its wrapping text never feeds back into the sheet's
/// `preferredContentSize` while the sheet opens.
struct CloudInfoPopoverButton: View {
    let title: String
    let text: String
    let learnMoreURL: URL
    let accessibilityIdentifier: String

    @State private var showsDetails = false

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
        .accessibilityIdentifier(accessibilityIdentifier)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .cmuxFont(size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                Link(String(localized: "cloud.security.learnMore", defaultValue: "Learn more"), destination: learnMoreURL)
                    .cmuxFont(size: 12)
                    .accessibilityIdentifier("\(accessibilityIdentifier).learnMore")
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}
