#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileLive
import Observation
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A Cloud machine's chats (``CloudMachineChatsList``, on the shared ``PagedList``) on fixed chats,
/// for screenshots and UI tests of every state (verify/paged-list.md), with the lab's measurement
/// line (`lab.hud`). Launch with `-cmux-mobile-paged-lab cloudchats:SCENARIO`:
/// - `fast`: 600 chats, all read: a page of 100 more shows as the reader nears the end;
/// - `slow`: 100 chats while the hub reads older ones: the end spins until `lab.deliver` hands the
///   list 100 more (as a page of the hub's read lands), up to 300;
/// - `end`: 150 chats, all read; `empty`: none;
/// - `connecting`: the machine never answers; `connectfail`: the connect failed (Retry connects,
///   then as `fast`);
/// - `reststop`: 100 chats, and the hub's read of older ones stopped short (Try Again reconnects,
///   then 300 chats, all read);
/// - `live`: 300 chats, all read; `lab.bump` updates a chat near the top (the 6th, then the 7th…),
///   which moves to the top, as a chat that just ran does.
/// `-cmux-mobile-paged-lab-clean` hides the measurement line and the buttons for screenshots.
struct CloudChatsGallery: View {
    let scheme: ColorScheme?
    let clean: Bool
    @State private var hub: CloudChatsGalleryHub
    @State private var shown = CloudChatList.pageSize
    @State private var hud = PagedLabHUD()
    @State private var probe = PagedListProbe()

    init(scenario: String, scheme: ColorScheme?, clean: Bool) {
        self.scheme = scheme
        self.clean = clean
        _hub = State(initialValue: CloudChatsGalleryHub(scenario: scenario))
    }

    var body: some View {
        let rows = Array(hub.chats.prefix(shown))
        let hasOlder = hub.chats.count > shown
        let edge = CloudMachineChatsList.edge(hasOlder: hasOlder, listWhole: hub.listWhole, restStopped: hub.restStopped)
        NavigationStack {
            Group {
                switch hub.state {
                case .connecting:
                    CloudChatsConnecting(machine: "Build Box", mac: "Studio Mac", since: hub.since)
                case .failed:
                    CloudChatsConnectFailed(cause: "Studio Mac didn't reach Build Box. Check that the Mac is awake and online.") {
                        Task { await hub.connect() }
                    }
                case .ready:
                    CloudMachineChatsList(rows: rows, hasOlder: hasOlder, listWhole: hub.listWhole, restStopped: hub.restStopped,
                                          shown: $shown, select: { _ in }, reconnect: { Task { await hub.connect() } }, probe: probe)
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle("Build Box")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !clean { controls(edge: edge) }
            }
        }
        .preferredColorScheme(scheme)
        .task {
            probe.pageLanded = { [hud] shift, rows in hud.landed(shift: shift, rows: rows) }
            probe.scrolling = { [hud] moving in hud.scrolling(moving) }
            await hub.connect()
        }
    }

    private func controls(edge: PagedListEdge) -> some View {
        VStack(spacing: 4) {
            Text(hud.line)
                .font(theme.type.meta)
                .monospacedDigit()
                .foregroundStyle(theme.colors.label2.color)
                .accessibilityIdentifier("lab.hud")
                .accessibilityValue(hud.json(edge: Self.name(edge)))
            HStack(spacing: 16) {
                Button("Deliver") { hub.deliver() }
                    .accessibilityIdentifier("lab.deliver")
                Button("Bump") { hub.bump() }
                    .accessibilityIdentifier("lab.bump")
            }
            .buttonStyle(.cmuxPressFill)
            .font(theme.type.meta)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.bar)
    }

    static func name(_ edge: PagedListEdge) -> String {
        switch edge {
        case .more: "more"
        case .loading: "loading"
        case .failed: "failed"
        case .end: "end"
        }
    }
}

/// What the gallery's Cloud machine holds: its chats newest first, whether the hub read them all
/// or its read stopped short, and the connect's state.
@MainActor
@Observable
final class CloudChatsGalleryHub {
    enum Phase { case connecting, failed, ready }

    let scenario: String
    private(set) var state = Phase.connecting
    private(set) var since = Date.now
    private(set) var chats: [CloudChatsListItem] = []
    private(set) var listWhole = false
    private(set) var restStopped = false
    @ObservationIgnored private var connects = 0
    @ObservationIgnored private var bumps = 0

    init(scenario: String) { self.scenario = scenario }

    func connect() async {
        connects += 1
        state = .connecting
        since = .now
        if scenario == "connecting" { return }
        // motion: not an animation; the gallery's machine answers after a network-like delay.
        try? await Task.sleep(for: .milliseconds(600))
        let again = connects > 1
        switch scenario {
        case "connectfail" where !again:
            state = .failed
            return
        case "empty":
            load(0, whole: true)
        case "end":
            load(150, whole: true)
        case "slow":
            load(100, whole: false)
        case "reststop":
            if again { load(300, whole: true) } else { load(100, whole: false, stopped: true) }
        case "live":
            load(300, whole: true)
        default:
            load(600, whole: true)
        }
        state = .ready
    }

    /// The next page of the hub's read lands (`slow`): 100 older chats, the last of them at 300.
    func deliver() {
        guard !listWhole else { return }
        let count = chats.count + 100
        chats += (chats.count..<count).map(Self.chat)
        listWhole = count >= 300
    }

    /// A chat near the top ran again: it moves to the top with its new prompt.
    func bump() {
        let id = "cc-\(5 + bumps)"
        bumps += 1
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let chat = chats.remove(at: index)
        chats.insert(CloudChatsListItem(id: chat.id, title: chat.title, prompt: "Ran again (\(bumps)): \(chat.prompt ?? "a new turn")"), at: 0)
    }

    private func load(_ count: Int, whole: Bool, stopped: Bool = false) {
        chats = (0..<count).map(Self.chat)
        listWhole = whole
        restStopped = stopped
    }

    static func chat(_ n: Int) -> CloudChatsListItem {
        let titles = ["Fix the flaky upload test", "Port the sidebar to Rust", "Review the Cloud billing PR", "Draft release notes",
                      "Profile the terminal flood", "Bump the Ghostty submodule", "Triage crash reports", "Write the onboarding copy"]
        let prompts = ["Run the suite again and tell me which test fails first.",
                       "Move the sidebar's sorting rules out of Swift into the core crate, keep the tests green, and open a PR against the feature branch when it builds.",
                       nil,
                       "Look at the diff and list anything that changes behavior.",
                       "Profile 60 seconds of cat on the 6 MB file and attach the trace."]
        return CloudChatsListItem(id: "cc-\(n)", title: "\(titles[n % titles.count]) \(n)", prompt: prompts[n % prompts.count])
    }
}
#endif
