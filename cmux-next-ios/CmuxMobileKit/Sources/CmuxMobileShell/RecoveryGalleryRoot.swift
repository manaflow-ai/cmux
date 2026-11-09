#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileTerminal
import CmuxSpinner
import SwiftUI

/// The loading and failure states, drawn by the production views with fixed
/// data, for screenshots of their Retry actions in light and dark.
/// Launch with `-cmux-mobile-recovery-gallery terminal|states|card`:
/// - `terminal`: a terminal page whose Mac is offline (the glass pill with Retry);
/// - `states`: the list-level empty state with Retry and a `ContentUnavailableView`
///   whose action is the shared Retry, as the chats, checkpoints and command pages use;
/// - `card`: the failure card, the connection banner with Retry, and the waiting card
///   a streamed simulator page shows;
/// - `cloud`: a Cloud machine's connect wait (A, the screen's, with the two
///   variants it was picked from), its failure with the cause, and Cloud chats
///   with no Mac to reach them through.
public struct RecoveryGalleryRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-recovery-gallery")
    }

    let scene: String

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let index = arguments.firstIndex(of: "-cmux-mobile-recovery-gallery")
        scene = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "states"
    }

    public var body: some View {
        Group {
            switch scene {
            case "terminal":
                TerminalConnectingView(state: .offline(mac: "Aziz's Mac Studio"), topInset: 60) {}
                    .background(Color.black)
            case "card":
                cards
            case "cloud":
                cloud
            default:
                states
            }
        }
        .ignoresSafeArea(edges: scene == "terminal" ? .all : [])
        .accessibilityIdentifier("recoveryGallery.\(scene)")
    }

    private var states: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load this Mac's Home.",
                       message: "Check that the Mac is awake and online.", retry: {})
            Divider()
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The Mac didn't answer in time.")
            } actions: {
                RetryButton {}
            }
        }
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    /// A (picked): spinner, what it waits on, and the bound, counted up past 5 s.
    /// B: an empty state with the bound and no motion (reads as stopped).
    /// C: an inline row with a determinate bar (implies progress the link does not report).
    private var cloud: some View {
        let since = Date.now.addingTimeInterval(-12)
        return ScrollView {
            VStack(spacing: 28) {
                galleryLabel("A · picked")
                CloudChatsConnecting(machine: "atlas-dev", mac: "Aziz's Mac Studio", since: since)
                galleryLabel("B")
                VStack(spacing: 6) {
                    Image(systemName: "cloud").font(.title2).foregroundStyle(.secondary)
                    Text("Connecting to atlas-dev").font(.headline)
                    Text("Through Aziz's Mac Studio. Gives up after 40 s.").font(.footnote).foregroundStyle(.secondary)
                }
                galleryLabel("C")
                HStack(spacing: 10) {
                    CmuxSpinner().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("atlas-dev via Aziz's Mac Studio").font(.subheadline)
                        ProgressView(value: 12, total: 40)
                    }
                }
                .padding(.horizontal, 20)
                galleryLabel("Timed out")
                CloudChatsConnectFailed(cause: "No answer from atlas-dev through Aziz's Mac Studio in 40 s.") {}
                    .frame(height: 300)
                galleryLabel("No Mac")
                CloudChatsConnectMac {}
                    .frame(height: 300)
            }
            .padding(.vertical, 60)
        }
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    private func galleryLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }

    private var cards: some View {
        VStack(spacing: 24) {
            ConnectionBanner(.offline, retry: {})
            FailureCard(title: "Couldn't load your teams", message: "Check your connection, then retry.") {}
                .padding(.horizontal, 20)
            VStack(spacing: 10) {
                Text("The simulator closed on your Mac.").font(.footnote).foregroundStyle(.secondary)
                RetryButton {}
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            Spacer()
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }
}
#endif
