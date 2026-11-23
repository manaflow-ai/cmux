public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// One account the Chief can act through (cmux issue 34263): Gmail or Google Calendar.
public struct HomeChiefConnection: Equatable, Sendable {
    public enum Provider: String, CaseIterable, Sendable {
        case gmail
        case googleCalendar = "google_calendar"
    }

    public enum State: Equatable, Sendable {
        case signedOut
        case unavailable
        case notConnected
        case pending
        case connected(account: String)
        case needsReauth
    }

    public var provider: Provider
    public var state: State
    /// The person made this connection, so Disconnect may revoke it.
    public var canDisconnect: Bool
    /// A Connect or Disconnect of it is running.
    public var working: Bool

    public init(provider: Provider, state: State, canDisconnect: Bool, working: Bool) {
        self.provider = provider
        self.state = state
        self.canDisconnect = canDisconnect
        self.working = working
    }

    public var title: String {
        switch provider {
        case .gmail: HomeEngineStrings.connectionGmail
        case .googleCalendar: HomeEngineStrings.connectionCalendar
        }
    }

    /// The trailing status words.
    public var status: String {
        switch state {
        case .signedOut: HomeEngineStrings.connectionSignedOut
        case .unavailable: HomeEngineStrings.connectionUnavailable
        case .notConnected: HomeEngineStrings.connectionNotConnected
        case .pending: HomeEngineStrings.connectionPending
        case .connected(let account): account
        case .needsReauth: HomeEngineStrings.connectionNeedsReauth
        }
    }

    /// The gesture the row's link runs, or nil when it shows none.
    public var action: Action? {
        guard !working else { return nil }
        switch state {
        case .signedOut, .unavailable: return nil
        case .notConnected, .pending: return .connect
        case .needsReauth: return .reconnect
        case .connected: return canDisconnect ? .disconnect : nil
        }
    }

    public enum Action: Equatable, Sendable {
        case connect, reconnect, disconnect

        public var title: String {
            switch self {
            case .connect: HomeEngineStrings.connectionConnect
            case .reconnect: HomeEngineStrings.connectionReconnect
            case .disconnect: HomeEngineStrings.connectionDisconnect
            }
        }
    }
}

/// The Chief Settings card's Connections section (cmux issue 34263): Gmail and Google Calendar, each
/// with its account and a Connect or Disconnect link. The list reloads when the card opens and
/// follows the app's connection model while it is open.
@MainActor
public final class HomeChiefConnectionsSection: NSStackView {
    public struct Source {
        /// The rows, read under observation so a finished connect shows at once.
        public var rows: @MainActor @Sendable () -> (rows: [HomeChiefConnection], failed: Bool)
        /// Reads the account's connections again (the card opened).
        public var refresh: @MainActor () -> Void
        /// Connect (`connect` true) or disconnect `provider`.
        public var act: @MainActor (_ provider: HomeChiefConnection.Provider, _ connect: Bool) -> Void

        public init(rows: @escaping @MainActor @Sendable () -> (rows: [HomeChiefConnection], failed: Bool),
                    refresh: @escaping @MainActor () -> Void,
                    act: @escaping @MainActor (HomeChiefConnection.Provider, Bool) -> Void) {
            self.rows = rows
            self.refresh = refresh
            self.act = act
        }
    }

    /// Set by the app; nil keeps the section hidden.
    public var source: Source? {
        didSet { if isOpen { open() } else { isHidden = source == nil } }
    }

    var onResize: () -> Void = {}
    private(set) var shown: [HomeChiefConnection] = []
    private var isOpen = false
    private var watch: Task<Void, Never>?
    private var rowViews: [HomeChiefConnection.Provider: (status: ThemedLabel, link: HomeChiefLinkButton)] = [:]
    private let failure = HomeChiefSettingsView.footnote(HomeEngineStrings.connectionFailed)

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space2
        setAccessibilityIdentifier("cmux.home.chief.connections")
        let header = HomeChiefSettingsView.sectionHeader(HomeEngineStrings.connectionsSection)
        addFull(header)
        for provider in HomeChiefConnection.Provider.allCases {
            let title = ThemedLabel(labelWithString: HomeChiefConnection(provider: provider, state: .unavailable, canDisconnect: false, working: false).title)
            title.font = Typography.body
            let status = ThemedLabel(labelWithString: "")
            status.font = Typography.body
            status.ink = .secondary
            status.lineBreakMode = .byTruncatingMiddle
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let link = HomeChiefLinkButton(title: HomeEngineStrings.connectionConnect, target: self, action: #selector(linked(_:)))
            link.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
            link.setAccessibilityIdentifier("cmux.home.chief.connection.\(provider.rawValue)")
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            let row = NSStackView(views: [title, spacer, status, link])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = Metrics.space2
            addFull(row)
            rowViews[provider] = (status, link)
        }
        failure.ink = .danger
        failure.preferredMaxLayoutWidth = HomeChiefSettingsView.width - 2 * HomeChiefSettingsView.inset
        failure.isHidden = true
        addFull(failure)
        let note = HomeChiefSettingsView.footnote(HomeEngineStrings.connectionsNote)
        note.preferredMaxLayoutWidth = HomeChiefSettingsView.width - 2 * HomeChiefSettingsView.inset
        addFull(note)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func addFull(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// The card opened: reload the list and follow it while the card is open.
    func open() {
        isOpen = true
        watch?.cancel()
        guard let source else {
            isHidden = true
            return
        }
        isHidden = false
        let rows = source.rows
        let (first, later) = ObservationStream.current { () -> Snapshot in
            let now = rows()
            return Snapshot(rows: now.rows, failed: now.failed)
        }
        show(first)
        // task-owner: the open card's connection watch; cancelled when the card closes
        watch = Task { [weak self] in
            for await snapshot in later { self?.show(snapshot) }
        }
        source.refresh()
    }

    func close() {
        isOpen = false
        watch?.cancel()
        watch = nil
    }

    struct Snapshot: Equatable, Sendable {
        var rows: [HomeChiefConnection]
        var failed: Bool
    }

    func show(_ snapshot: Snapshot) {
        shown = snapshot.rows
        for row in snapshot.rows {
            guard let views = rowViews[row.provider] else { continue }
            views.status.stringValue = row.status
            views.status.toolTip = row.status
            if let action = row.action {
                views.link.linkTitle = action.title
                views.link.isHidden = false
            } else {
                views.link.isHidden = true
            }
        }
        let resized = failure.isHidden == snapshot.failed
        failure.isHidden = !snapshot.failed
        if resized { onResize() }
    }

    @objc private func linked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let provider = HomeChiefConnection.Provider(rawValue: raw),
              let row = shown.first(where: { $0.provider == provider }), let action = row.action else { return }
        source?.act(provider, action != .disconnect)
    }
}
