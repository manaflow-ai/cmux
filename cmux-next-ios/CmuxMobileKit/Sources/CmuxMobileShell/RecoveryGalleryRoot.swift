#if DEBUG && os(iOS)
import CmuxMobileChief
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
/// - `home`: Home's "Couldn't load" note with its capsule Retry, twice: one whose
///   read answers at once (Home's retry before it waited for the read) and one
///   whose read takes about a second (a real network answer);
/// - `cloud`: a Cloud machine's connect wait (A, the screen's, with the two
///   variants it was picked from), its failure with the cause, and Cloud chats
///   with no Mac to reach them through;
/// - `chiefoff`: Home's "Chief Is Off" card (the Cloud Chief's brain is off, as every new
///   account's is): A, the one Home shows, in its four states (off, turning on, failed,
///   unavailable on this account), then the variants it was picked from, B and C;
/// - `cloudmachines`: Settings → Cloud → Cloud Machines with fixed machines, plan and snapshots.
public struct RecoveryGalleryRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-recovery-gallery")
    }

    let scene: String
    /// `-cmux-mobile-gallery-appearance light|dark`: the scheme the shots use (else the system's).
    let scheme: ColorScheme?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let index = arguments.firstIndex(of: "-cmux-mobile-recovery-gallery")
        scene = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "states"
        let look = arguments.firstIndex(of: "-cmux-mobile-gallery-appearance").flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        scheme = look == "dark" ? .dark : look == "light" ? .light : nil
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
            case "home":
                home
            case "chiefoff":
                chiefOff
            case "signedout":
                signedOut
            case "cloudmachines":
                NavigationStack { CloudMachinesScreen(model: .gallery(), openChats: {}) }
            default:
                states
            }
        }
        .ignoresSafeArea(edges: scene == "terminal" ? .all : [])
        .accessibilityIdentifier("recoveryGallery.\(scene)")
        .preferredColorScheme(scheme)
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

    private var home: some View {
        VStack(spacing: 48) {
            homeNote(id: "instant") {}
            homeNote(id: "slow") { try? await ContinuousClock().sleep(for: .milliseconds(1200)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    /// The Home list's problem row as ConversationsHome draws it.
    private func homeNote(id: String, read: @escaping @MainActor () async -> Void) -> some View {
        VStack(spacing: 6) {
            Text(RecoveryMessage.home.text)
                .font(.footnote)
                .foregroundStyle(CmuxMobileTheme.standard.colors.label2.color)
            RetryButton(action: read).accessibilityIdentifier("recoveryGallery.home.retry.\(id)")
        }
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

    /// A (picked): SPEC 7.3's inline failure card, the shape every failure card in the
    /// app has, so the state reads as something to act on, with its one button.
    /// B: a centered note as Home's other notes (reads as fine print; easy to miss).
    /// C: the Chief's row with the button trailing (reads as a chat, and a tap on the row
    /// would open a Chief that does not answer).
    private var chiefOff: some View {
        ScrollView {
            VStack(spacing: 20) {
                galleryLabel("A · picked · off")
                ChiefOffCardView(.off) {}.padding(.horizontal, 16)
                galleryLabel("A · turning on")
                ChiefOffCardView(.turningOn) {}.padding(.horizontal, 16)
                galleryLabel("A · failed")
                ChiefOffCardView(.failed) {}.padding(.horizontal, 16)
                galleryLabel("A · unavailable on this account")
                ChiefOffCardView(.unavailable) {}.padding(.horizontal, 16)
                galleryLabel("B · note")
                ChiefOffCardView(.off, style: .note) {}.padding(.horizontal, 16)
                galleryLabel("C · row")
                ChiefOffCardView(.off, style: .row) {}.padding(.horizontal, 16)
            }
            .padding(.vertical, 60)
        }
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    private func galleryLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }

    /// The signed-out banner where the Workspaces list shows it (`-cmux-mobile-recovery-gallery signedout`).
    private var signedOut: some View {
        List {
            ForEach(["cmux", "api", "web"], id: \.self) { Text($0) }
        }
        .cmuxMobileBanner(.signedOut, retry: {})
    }

    private var cards: some View {
        VStack(spacing: 24) {
            ConnectionBanner(.offline, retry: {})
            ConnectionBanner(.signedOut, retry: {})
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
