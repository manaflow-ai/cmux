#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Browser: where a browser page opened while linked to a Mac shows
/// (`BrowserOpenDefault`). A checkmarked list of the three choices, as iOS Settings
/// lists one choice of a few (Mail → Preview, Safari → Open Links), and under
/// Automatic what it decides for each kind of page.
struct BrowserSettingsPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach(BrowserOpenDefault.allCases) { choice in
                    Button {
                        settings.browserOpenDefault = choice
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).foregroundStyle(theme.colors.label)
                                Text(Self.detail(choice))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if settings.browserOpenDefault == choice {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.cmuxPressFill)
                    .accessibilityAddTraits(settings.browserOpenDefault == choice ? .isSelected : [])
                    .accessibilityIdentifier("settings.browser.openDefault.\(choice.rawValue)")
                }
            } header: {
                Text("Open New Pages")
            } footer: {
                Text("For browser tabs opened from now on, here or on the Mac. A tab's menu still switches it with Open on iPhone or Mirror from Mac.")
            }
            if settings.browserOpenDefault == .automatic {
                Section {
                    ForEach(Self.automaticRules, id: \.title) { rule in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: rule.onPhone ? "iphone" : "play.display")
                                .frame(width: 22)
                                .foregroundStyle(rule.onPhone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title).foregroundStyle(theme.colors.label)
                                Text(rule.example).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(rule.onPhone ? "iPhone" : "Stream")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("How Automatic Decides")
                } footer: {
                    Text("Pages only the Mac can open (its files other than web pages, an older Mac's localhost) always stream.")
                }
            } else if settings.browserOpenDefault == .phone {
                Section {
                    Label("Sign-ins on the Mac don't carry over to this iPhone. Pages only the Mac can open, such as an older Mac's localhost, still stream.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsPage("Browser")
    }

    static func detail(_ choice: BrowserOpenDefault) -> String {
        switch choice {
        case .automatic: String(localized: "Public pages and HTML files open on this iPhone; signed-in sites and private hosts stream from the Mac.")
        case .phone: String(localized: "Every page this iPhone can load opens in its own browser.")
        case .stream: String(localized: "Every page shows the Mac's browser, streamed.")
        }
    }

    struct Rule {
        var title: String
        var example: String
        var onPhone: Bool
    }

    /// Mirrors `BrowserPagePlacement.decide` for `.automatic` (CmuxMobileWorkspaces).
    static let automaticRules: [Rule] = [
        Rule(title: String(localized: "Public web pages"), example: "example.com", onPhone: true),
        Rule(title: String(localized: "HTML files on the Mac"), example: "report.html", onPhone: true),
        Rule(title: String(localized: "The Mac's localhost"), example: "localhost:3000", onPhone: true),
        Rule(title: String(localized: "Sites you're signed in to"), example: "github.com, linear.app, /login", onPhone: false),
        Rule(title: String(localized: "Private and tailnet hosts"), example: "mac.local, *.ts.net, 10.0.0.5", onPhone: false),
        Rule(title: String(localized: "New blank tabs"), example: String(localized: "No address yet"), onPhone: false),
    ]
}
#endif
