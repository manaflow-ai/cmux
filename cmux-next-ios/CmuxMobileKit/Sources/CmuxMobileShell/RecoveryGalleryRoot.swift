#if DEBUG && os(iOS)
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
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
/// - `cloudmachines`: Settings → Cloud → Cloud Machines with fixed machines, plan and snapshots;
///   `cloudmachines-held`: the same with a start and a new machine waiting for approval in the Feed.
/// - `theme-mocha`, `theme-solarized`, `theme-wallpaper`: the chrome under a Mac's theme (`MacThemeGallery`).
/// - `chip`: the terminal's connection chip (Leo 2026-11-21: "a symbol or short thing,
///   not a sentence. stop layout shifting"): A, the top-center toast the terminal shows,
///   in its four states; B, the chip just above the composer at the leading edge (the
///   agent chat's); C, symbol only at the trailing edge.
/// - `chiplist`: a list's connection state (the Workspaces list, Home, Agent Chats) as a chip over
///   the rows, which never move: A, top center (the one `cmuxMobileBanner` draws), in the link
///   states and over the signed-out banner; B, top leading; C, symbol only at the top trailing edge.
/// - `stills`: what a tab card's picture draws for math, a running tool's spinner and a menu, A (the
///   app's), B and C, each through `ImageRenderer` (`StillPictureGallery`).
/// - `keybar`: the terminal key row's layouts, A (the default), B and C (`TerminalKeyBarGallery`).
/// - `lastsent`: the terminal's top strip back to the last line sent (Leo 2026-11-23: "click (tap)
///   the top bit of the terminal in phone to jump to that last sent bit"): A, the pill the page
///   shows; B, a full-width bar; C, the top edge alone (`TerminalLastSentGallery`).
/// - `favicons`: browser tab cards with no picture: today's globe, then the site monogram (A, Settings
///   → Advanced → Site Monograms on Tab Cards) and the variants it was picked from, B and C.
/// - `quiet-before`, `quiet-a`, `quiet-b`, `quiet-c`: the places that said "Updating…" over rows
///   the phone had, before and in three variants (Leo 2026-11-24: "they dont need to know that
///   it's updating before they KNOW it's updating"); A is the one the app shows (`QuietUpdatingGallery`).
/// - `skeleton`: the Workspaces list's placeholder rows with nothing cached (Leo 2026-11-24: "i noticed
///   the skeleton for this was a bit off on ios"; 2026-11-12: "just show the cache"): A, the rows at the
///   list's text column and row height with the caption spoken only (the one the list shows); B, the
///   caption under the rows; C, the caption above them at the text column; then the rows before.
///   `skeleton-a`, `-b`, `-c`, `-before` draw one each, full page, for side-by-side shots.
/// - `reconnect`: a list riding out a dropped or quiet connection to the Mac with its rows kept
///   (Leo 2026-11-21: no "didn't answer in time"): A, the line the Chats list shows
///   (`ListStatusRow`), in its three states, then the variants it was picked from, B and C.
/// - `agentmark`: a terminal agent's avatar beside a GUI agent chat's (Leo 2026-11-24: "both of them rn
///   are just claude icon"), every variant side by side; `agentmark-a` ... `agentmark-d`, one variant on
///   Feed-like rows (`AgentAvatarHostGallery`).
public struct RecoveryGalleryRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-recovery-gallery")
    }

    let scene: String
    /// `chip-b`, `chiplist-c`: one variant of a variants scene, so each gets its own shot.
    let variant: String?
    /// `-cmux-mobile-gallery-appearance light|dark`: the scheme the shots use (else the system's).
    let scheme: ColorScheme?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let index = arguments.firstIndex(of: "-cmux-mobile-recovery-gallery")
        let named = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "states"
        let parts = named.split(separator: "-", maxSplits: 1).map(String.init)
        if ["chip", "chiplist", "quiet", "stills", "skeleton", "agentmark"].contains(parts[0]), parts.count == 2 {
            scene = parts[0]
            variant = parts[1]
        } else {
            scene = named
            variant = nil
        }
        let look = arguments.firstIndex(of: "-cmux-mobile-gallery-appearance").flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil }
        scheme = look == "dark" ? .dark : look == "light" ? .light : nil
    }

    public var body: some View {
        Group {
            switch scene {
            case "terminal":
                TerminalConnectingView(topInset: 60)
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
            case "reconnect":
                reconnect
            case "skeleton":
                skeletons
            case "chip":
                connectionChips
            case "chiplist":
                listChips
            case "quiet":
                QuietUpdatingGallery(variant: variant ?? "a")
            case "cloudmachines-held":
                NavigationStack { CloudMachinesScreen(model: .gallery(held: true), openChats: {}) }
            case "theme-mocha", "theme-solarized", "theme-wallpaper":
                MacThemeGallery(variant: scene)
            case "keybar":
                TerminalKeyBarGallery()
            case "stills":
                // `stills-mocha`, `stills-solarized`: the same under a Mac's dark or light theme.
                StillPictureGallery()
                    .onAppear {
                        guard let fixture = variant == "mocha" ? MacThemeGallery.mocha : variant == "solarized" ? MacThemeGallery.solarized : nil else { return }
                        CmuxMobileMacTheme.shared.matchesMac = true
                        CmuxMobileMacTheme.shared.apply(fixture, chatWallpaper: nil)
                    }
            case "lastsent":
                TerminalLastSentGallery()
            case "favicons":
                SiteMonogramGallery()
            case "agentmark":
                AgentAvatarHostGallery(variant: variant)
            default:
                states
            }
        }
        .ignoresSafeArea(edges: scene == "terminal" ? .all : [])
        .accessibilityIdentifier("recoveryGallery.\(scene)")
        .preferredColorScheme(scheme)
    }

    /// The Workspaces placeholder rows, as `skeleton` above describes.
    @ViewBuilder private var skeletons: some View {
        if let variant {
            NavigationStack {
                ScrollView { skeleton(variant) }
                    .scrollDisabled(true)
                    .navigationTitle("Workspaces")
                    .navigationBarTitleDisplayMode(.large)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    galleryLabel("A · picked · caption spoken")
                    skeleton("a")
                    galleryLabel("B · caption under the rows")
                    skeleton("b")
                    galleryLabel("C · caption above, at the text column")
                    skeleton("c")
                    galleryLabel("Before")
                    skeleton("before")
                }
                .padding(.vertical, 60)
            }
            .background(CmuxMobileTheme.standard.colors.bg.color)
        }
    }

    @ViewBuilder private func skeleton(_ variant: String) -> some View {
        let caption: LocalizedStringKey = "Loading workspaces…"
        switch variant {
        case "b": SkeletonList(rows: 3, delay: .zero, caption: caption, style: .plainList, captionPlacement: .below)
        case "c": SkeletonList(rows: 3, delay: .zero, caption: caption, style: .plainList, captionPlacement: .above)
        case "before": SkeletonList(rows: 3, delay: .zero, caption: caption)
        default: SkeletonList(rows: 3, delay: .zero, caption: caption, style: .plainList, captionPlacement: .spoken)
        }
    }

    private var states: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load this Mac's Home.",
                       message: "Check that the Mac is awake and online.", retry: {})
            Divider()
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } description: {
                Text(ConnectionInterrupted.message)
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

    /// A (picked): nothing while it connects; the chats fill in (Leo, 2026-11-24, item 3: no
    /// connecting indicators). Was: spinner, what it waits on, and the bound, counted up past 5 s.
    /// B: an empty state with the bound and no motion (reads as stopped).
    /// C: an inline row with a determinate bar (implies progress the link does not report).
    private var cloud: some View {
        ScrollView {
            VStack(spacing: 28) {
                galleryLabel("A · picked")
                CloudChatsConnecting()
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

    /// A (picked): a quiet line at the top of the list, the same place and type the list's old
    /// "Updating…" line used, so a blip does not read as a problem; rows stay tappable.
    /// B: a floating glass pill over the bottom of the list (motion over content; covers the
    /// last row and competes with the tab bar).
    /// C: a thin indeterminate bar under the title with the rows dimmed (reads as blocked, and
    /// dimming invites a tap that does nothing different).
    /// The terminal page's three chip placements (`chip`, or one of them: `chip-a|b|c`).
    private var connectionChips: some View {
        let states = TerminalChipPage.states
        return ScrollView {
            VStack(spacing: 12) {
                if showsVariant("a") {
                    // visible-only: four fixed states.
                    ForEach(states, id: \.self) { state in
                        galleryLabel("A · top center · \(state.word)")
                        TerminalChipPage(variant: .a, state: state)
                    }
                }
                if showsVariant("b") {
                    galleryLabel("B · above the composer, leading")
                    TerminalChipPage(variant: .b, state: states[1])
                }
                if showsVariant("c") {
                    galleryLabel("C · symbol only, trailing · \(states[2].word)")
                    TerminalChipPage(variant: .c, state: states[2])
                }
            }
            .padding()
        }
    }

    private var reconnect: some View {
        let rows = ["Fix the login redirect", "Bump the parser to 2.4", "Why is CI slow on arm64?"]
        func list(_ status: ListStatusRow.State?, dimmed: Bool = false) -> some View {
            List {
                if let status { ListStatusRow(status) }
                // visible-only: a fixed gallery of three rows.
                ForEach(rows, id: \.self) { Text($0).opacity(dimmed ? 0.45 : 1) }
            }
            .listStyle(.insetGrouped)
            .scrollDisabled(true)
            .frame(height: 230)
        }
        return ScrollView {
            VStack(spacing: 12) {
                galleryLabel("A · picked · reconnecting")
                list(.reconnecting)
                galleryLabel("A · past the bound, rows kept")
                list(.stale)
                galleryLabel("A · empty list, connecting")
                CmuxSpinner(label: Text("Connecting to your Mac…")).frame(height: 120)
                galleryLabel("B · floating pill")
                list(nil)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 8) {
                            CmuxSpinner().controlSize(.small)
                            Text("Reconnecting…").font(.footnote.weight(.medium))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 12)
                    }
                galleryLabel("C · top bar, rows dimmed")
                list(nil, dimmed: true)
                    .overlay(alignment: .top) {
                        ProgressView().progressViewStyle(.linear).padding(.horizontal, 20)
                    }
            }
            .padding(.vertical, 60)
        }
        .accessibilityIdentifier("recoveryGallery.reconnect.variants")
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    private var listChips: some View {
        let rows = ["cmux · Fix the login redirect", "api · Bump the parser to 2.4", "web · Why is CI slow on arm64?",
                    "cmux · Land the chip", "infra · Rotate runners"]
        func list<Chip: View>(_ alignment: Alignment, @ViewBuilder chip: () -> Chip) -> some View {
            List {
                // visible-only: a fixed gallery of five rows.
                ForEach(rows, id: \.self) { Text($0) }
            }
            .listStyle(.insetGrouped)
            .scrollDisabled(true)
            .frame(height: 280)
            .overlay(alignment: alignment) { chip().padding(.top, 8).padding(.horizontal, 20) }
        }
        let states: [ConnectionBannerState] = [.connectionFailed, .macOffline("Mac Studio"), .offline]
        return ScrollView {
            VStack(spacing: 12) {
                if showsVariant("a") {
                // visible-only: three fixed link states.
                ForEach(states, id: \.self) { state in
                    galleryLabel("A · top center · \(state.chip?.word ?? state.text)")
                    List {
                        // visible-only: a fixed gallery of five rows.
                        ForEach(rows, id: \.self) { Text($0) }
                    }
                    .listStyle(.insetGrouped)
                    .scrollDisabled(true)
                    .frame(height: 280)
                    .cmuxMobileBanner(state, retry: {})
                }
                galleryLabel("A · signed out: the banner, also over the rows")
                List {
                    // visible-only: a fixed gallery of five rows.
                    ForEach(rows, id: \.self) { Text($0) }
                }
                .listStyle(.insetGrouped)
                .scrollDisabled(true)
                .frame(height: 280)
                .cmuxMobileBanner(.signedOut, retry: {})
                }
                if showsVariant("b") {
                    galleryLabel("B · top leading")
                    list(.topLeading) { ConnectionChip(ConnectionBannerState.connectionFailed.chip!, downSince: nil) }
                }
                if showsVariant("c") {
                    galleryLabel("C · symbol only, top trailing · Mac offline")
                    list(.topTrailing) { ConnectionChip.SymbolOnly(ConnectionBannerState.macOffline("Mac Studio").chip!, downSince: nil) }
                }
            }
            .padding(.vertical, 60)
        }
        .accessibilityIdentifier("recoveryGallery.chiplist.variants")
        .background(CmuxMobileTheme.standard.colors.bg.color)
    }

    private func showsVariant(_ name: String) -> Bool { variant == nil || variant == name }

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
