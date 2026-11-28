#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileLive
import Observation
import QuartzCore
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A Cloud machine's chats (``CloudMachineChatsList``, on the shared ``PagedList``) on fixed chats,
/// for screenshots and UI tests of every state (verify/paged-list.md), with the lab's measurement
/// line (`lab.hud`). Launch with `-cmux-mobile-paged-screen cloudchats:SCENARIO`:
/// - `fast`: 600 chats: a page of 100 more is read as the reader nears the end, and lands at once;
/// - `slow`: 300 chats: a page more is read slowly, so the end spins until `lab.deliver` answers
///   the read (as acpmux's page lands);
/// - `end`: 150 chats; `empty`: none;
/// - `connecting`: the machine never answers (nothing is drawn); `connectfail`: the connect failed
///   (it connects again on its own, then as `fast`);
/// - `olderfail`: 300 chats, and the first read of a page more fails (the end's Try Again reads it);
/// - `live`: 300 chats; `lab.bump` updates a chat near the top (the 6th, then the 7th…), which
///   moves to the top, as a chat that just ran does.
/// `-cmux-mobile-paged-lab-clean` hides the measurement line and the buttons for screenshots.
struct CloudChatsGallery: View {
    let scheme: ColorScheme?
    let clean: Bool
    @State private var hub: CloudChatsGalleryHub
    @State private var shown = CloudChatList.pageSize
    /// The connect is made again on its own, as the screen's (a slower first retry, so a test sees the failure).
    @State private var autoRetry = AutoRetry(backoff: AutoRetryBackoff(first: .seconds(4), cap: .seconds(4)))
    @State private var hud = PagedLabHUD()
    @State private var probe = PagedListProbe()
    @State private var hitchLog = CloudChatsHitchLog()

    init(scenario: String, scheme: ColorScheme?, clean: Bool) {
        self.scheme = scheme
        self.clean = clean
        _hub = State(initialValue: CloudChatsGalleryHub(scenario: scenario))
    }

    var body: some View {
        let state = CloudChatsListState(rows: hub.rows, hasOlder: hub.hasOlder, pageShown: hub.pageShown, shown: shown,
                                        failure: hub.failure)
        NavigationStack {
            Group {
                switch hub.state {
                case .connecting:
                    CloudChatsConnecting()
                case .failed:
                    CloudChatsConnectFailed(cause: "Studio Mac didn't reach Build Box. Check that the Mac is awake and online.",
                                            autoRetry: autoRetry)
                case .ready:
                    CloudMachineChatsList(state: state, shown: $shown, select: { _ in },
                                          retry: { Task { await hub.read(shown: shown, again: true) } }, probe: probe)
                }
            }
            .autoRetry(autoRetry, failing: hub.state == .failed) { await hub.connect() }
            // A page more is read when the list asks for it, as the screen reads acpmux's.
            .task(id: shown) { await hub.read(shown: shown) }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle("Build Box")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !clean { controls(edge: state.edge) }
            }
        }
        .preferredColorScheme(scheme)
        .task {
            probe.pageLanded = { [hud, hitchLog] shift, rows in
                hud.landed(shift: shift, rows: rows)
                hitchLog.landed(rows: rows)
            }
            probe.scrolling = { [hud, hitchLog] moving in
                hud.scrolling(moving)
                hitchLog.scrolling(moving)
            }
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
            // Each hitch: when, how long, the main thread's CPU in it, and the nearest page landing.
            Text(verbatim: "hitches \(hitchLog.hitches.count)")
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2.color)
                .accessibilityIdentifier("lab.hitches")
                .accessibilityValue(hitchLog.json)
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

/// Every hitch of the gallery's scrolls, each with the main thread's CPU time in its frame and how
/// far it was from the nearest page landing: a hitch at a landing with a busy main thread is the
/// list's work; one far from any landing with an idle main thread is the simulator's renderer.
@MainActor
@Observable
final class CloudChatsHitchLog {
    struct Hitch: Codable {
        var ms: Double
        var cpuMs: Double?
        /// Seconds from the hitch's frame to the nearest page landing in its window (nil: none).
        var fromLanding: Double?
        var rowsAtLanding: Int?
    }

    private(set) var hitches: [Hitch] = []
    @ObservationIgnored private let log = FrameIntervalLog(enabled: true)
    @ObservationIgnored private var start: CFTimeInterval = 0
    @ObservationIgnored private var landings: [(at: CFTimeInterval, rows: Int)] = []

    init() {
        log.onSummary = { [weak self] stats in self?.add(stats) }
    }

    func scrolling(_ moving: Bool) {
        if moving {
            log.begin("cloud-chats")
            start = CACurrentMediaTime()
            landings = []
        } else {
            log.end()
        }
    }

    func landed(rows: Int) {
        landings.append((CACurrentMediaTime() - start, rows))
    }

    private func add(_ stats: FrameIntervalStats) {
        guard let intervals = stats.intervalsMs else { return }
        let cpu = stats.mainThreadCPUPerFrameMs
        var at = 0.0
        for (index, ms) in intervals.enumerated() {
            at += ms / 1000
            guard ms > stats.expectedMs * 1.5 else { continue }
            let nearest = landings.min { abs($0.at - at) < abs($1.at - at) }
            hitches.append(Hitch(ms: ms, cpuMs: cpu.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                                 fromLanding: nearest.map { (($0.at - at) * 1000).rounded() / 1000 }, rowsAtLanding: nearest?.rows))
        }
    }

    var json: String {
        (try? String(decoding: JSONEncoder().encode(hitches), as: UTF8.self)) ?? "[]"
    }
}

/// What the gallery's Cloud machine holds (its chats newest first), the page of them read last, and
/// the connect's state: the screen's acpmux page read, on fixed chats.
@MainActor
@Observable
final class CloudChatsGalleryHub {
    enum Phase { case connecting, failed, ready }

    let scenario: String
    private(set) var state = Phase.connecting
    /// The chats drawn: the first `pageShown` of the machine's.
    private(set) var rows: [CloudChatsListItem] = []
    private(set) var hasOlder = false
    private(set) var pageShown = 0
    /// The last read of a page more failed.
    private(set) var failure: String?
    @ObservationIgnored private var all: [CloudChatsListItem] = []
    @ObservationIgnored private var connects = 0
    @ObservationIgnored private var bumps = 0
    @ObservationIgnored private var failedOnce = false
    /// `slow`: the read of a page more waits here until `deliver`.
    @ObservationIgnored private var held: CheckedContinuation<Void, Never>?

    init(scenario: String) { self.scenario = scenario }

    func connect() async {
        connects += 1
        state = .connecting
        if scenario == "connecting" { return }
        // motion: not an animation; the gallery's machine answers after a network-like delay.
        try? await Task.sleep(for: .milliseconds(600))
        if scenario == "connectfail", connects == 1 {
            state = .failed
            return
        }
        switch scenario {
        case "empty": all = []
        case "end": all = (0..<150).map(Self.chat)
        case "slow", "olderfail", "live": all = (0..<300).map(Self.chat)
        default: all = (0..<600).map(Self.chat)
        }
        page(CloudChatList.pageSize)
        state = .ready
    }

    /// Reads the first `shown` chats, as the screen reads acpmux's page: a page more is slow in
    /// `slow` (until `deliver`) and fails once in `olderfail`.
    func read(shown: Int, again: Bool = false) async {
        guard state == .ready, shown > pageShown, hasOlder else { return }
        if again { failure = nil }
        switch scenario {
        case "slow":
            // One read waits at a time: an earlier one answers first.
            deliver()
            await withCheckedContinuation { held = $0 }
        case "olderfail" where !failedOnce:
            failedOnce = true
            failure = "Couldn't load older chats."
            return
        default:
            break
        }
        page(shown)
    }

    /// The slow read of a page more answers (`slow`).
    func deliver() {
        held?.resume()
        held = nil
    }

    /// A chat near the top ran again: it moves to the top with its new prompt.
    func bump() {
        let id = "cc-\(5 + bumps)"
        bumps += 1
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let chat = all.remove(at: index)
        all.insert(CloudChatsListItem(id: chat.id, title: chat.title, prompt: "Ran again (\(bumps)): \(chat.prompt ?? "a new turn")"), at: 0)
        page(pageShown)
    }

    private func page(_ shown: Int) {
        rows = Array(all.prefix(shown))
        hasOlder = all.count > shown
        pageShown = shown
        failure = nil
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
