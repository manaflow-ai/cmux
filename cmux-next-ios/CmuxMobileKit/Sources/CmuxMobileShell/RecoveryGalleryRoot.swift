#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileTerminal
import SwiftUI

/// The loading and failure states, drawn by the production views with fixed
/// data, for screenshots of their Retry actions in light and dark.
/// Launch with `-cmux-mobile-recovery-gallery terminal|states|card`:
/// - `terminal`: a terminal page whose Mac is offline (the glass pill with Retry);
/// - `states`: the list-level empty state with Retry and a `ContentUnavailableView`
///   whose action is the shared Retry, as the chats, checkpoints and command pages use;
/// - `card`: the failure card, the connection banner with Retry, and the waiting card
///   a streamed simulator page shows.
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
