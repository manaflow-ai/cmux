public import AppKit
public import CmuxNextActions
import CmuxNextApps
public import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation

/// The sidebar's Apps section's data (RFD 0003 E-C, behind `experiments.appsTier`, off by default):
/// the account's apps from the relay (`cloud apps-relay`, `{op: "list"}`) laid out by Rust
/// (``AppsTierRules/section(_:)``). It reads the list when the experiment turns on and when the
/// signed-in person changes, and after each live publish (``AppsTierPreviews/publishes``). With the experiment off it holds
/// nothing and the section does not show.
public final class AppsTierSidebarFeed {
    /// The section as Rust laid it out; nil before the first answer.
    public private(set) var section: AppsTierRules.Section?
    /// Whether the section shows: the experiment is on.
    public private(set) var isOn = false
    /// Runs when what the section draws changed (shown, hidden, new rows).
    public var onChange: (() -> Void)?

    private let isEnabled: @MainActor @Sendable () -> Bool
    private let account: @MainActor @Sendable () -> String?
    private let relay: () -> (@Sendable (Data) async -> Data)
    private let perform: (ActionID, [String: ActionValue]) -> Bool
    private let publishes: @MainActor @Sendable () -> Int
    private let publishFocused: () -> Bool
    private let rules = AppsTierRules()
    private var reading: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var view: AppsTierSectionView?

    /// `isEnabled`: the experiment's switch; `account`: the signed-in person (nil signed out);
    /// `relay`: the CLI's apps relay; `perform`: runs an action by id; `publishes`: the live publishes
    /// so far; `publishFocused`: the focused page's Publish (false when it has none).
    public init(isEnabled: @escaping @MainActor @Sendable () -> Bool, account: @escaping @MainActor @Sendable () -> String?,
                relay: @escaping () -> (@Sendable (Data) async -> Data),
                perform: @escaping (ActionID, [String: ActionValue]) -> Bool,
                publishes: @escaping @MainActor @Sendable () -> Int = { 0 }, publishFocused: @escaping () -> Bool = { false }) {
        self.isEnabled = isEnabled
        self.account = account
        self.relay = relay
        self.perform = perform
        self.publishes = publishes
        self.publishFocused = publishFocused
    }

    /// The app's feed: the experiment's switch, the signed-in account (`auth`), the bundled CLI's
    /// apps relay (`cli`), the app's actions (`registry`), its previews (`previews`) and the focused page's Publish.
    public convenience init(isEnabled: @escaping @MainActor @Sendable () -> Bool, auth: CloudAuth, cli: BundledExecutable, registry: ActionRegistry,
                            previews: AppsTierPreviews, publishFocused: @escaping () -> Bool) {
        self.init(isEnabled: isEnabled,
                  account: { [weak auth] in auth?.isSignedIn == true ? auth?.user?.id ?? "" : nil },
                  relay: { [weak auth] in auth.map { CloudCLICall(cli: cli).appsRelay(signedIn: $0) } ?? { _ in Data() } },
                  perform: { [weak registry] id, arguments in
                      registry?.perform(id, invocation: ActionInvocation(arguments: arguments, origin: .user)) == true
                  },
                  publishes: { [weak previews] in previews?.publishes ?? 0 },
                  publishFocused: publishFocused)
    }

    /// Follows the setting and the account: one read per change.
    public func start() {
        guard watch == nil else { return }
        let isEnabled = isEnabled, account = account, publishes = publishes
        // task-owner: the feed's one observation of the setting and the account; it ends with the feed.
        watch = Task { [weak self] in
            for await watched in ObservationStream({ Watched(on: isEnabled(), account: account(), publishes: publishes()) }) {
                guard let self else { return }
                apply(on: watched.on)
            }
        }
    }

    /// Stops reading (the window's sidebar went away).
    public func stop() {
        watch?.cancel()
        watch = nil
        reading?.cancel()
        reading = nil
        view = nil
    }

    private func apply(on: Bool) {
        let shown = isOn
        isOn = on
        guard on else {
            reading?.cancel()
            section = nil
            if shown { changed() }
            return
        }
        if !shown { changed() }
        refresh()
    }

    /// Reads the account's list again (the experiment on; after a publish); the last read wins.
    public func refresh() {
        guard isOn else { return }
        reading?.cancel()
        let forward = relay(), rules = rules
        // task-owner: one list read; a newer read cancels it.
        reading = Task { [weak self] in
            let reply = await forward(Data(#"{"op":"list"}"#.utf8))
            guard !Task.isCancelled, let self, isOn else { return }
            let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
                ?? ["ok": false, "error": ["message": "unreadable reply"]]
            section = rules.section(json) ?? .empty
            changed()
        }
    }

    private func changed() {
        view?.show(AppsTierSectionView.Model(rows: section?.rows.map { AppsTierSectionView.Row(title: $0.title, detail: $0.detail, live: $0.live) },
                                             publishRow: section?.publishRow ?? true, error: section?.error))
        onChange?()
    }

    /// The section's view while it shows, made once (``AppsTierSectionView``); nil while off.
    public func sectionView() -> NSView? {
        guard isOn else { return nil }
        if let view { return view }
        let made = AppsTierSectionView(openRow: { [weak self] index in
            guard let rows = self?.section?.rows, rows.indices.contains(index) else { return }
            self?.open(rows[index])
        }, publish: { [weak self] in self?.publishPreview() == true })
        made.onHeightChange = { [weak self] in self?.onChange?() }
        view = made
        changed()
        return made
    }

    /// The section's height as drawn.
    public var preferredHeight: CGFloat { view?.preferredHeight ?? 0 }

    /// The sidebar dropped the section's view.
    public func releaseView() { view = nil }

    /// A row's click: a live app opens in a browser tab, through the one browser-open path.
    public func open(_ row: AppsTierRules.Row) {
        guard let url = row.url else { return }
        _ = perform("openBrowser", ["url": .string(url)])
    }

    /// The `+ Publish preview…` row: the focused browser pane's Publish (its popover); false when
    /// nothing could publish here.
    public func publishPreview() -> Bool {
        publishFocused()
    }

    private struct Watched: Equatable, Sendable {
        var on: Bool
        var account: String?
        var publishes: Int
    }
}
