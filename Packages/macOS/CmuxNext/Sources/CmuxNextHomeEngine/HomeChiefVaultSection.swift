public import AppKit
import CmuxNextCloud
import CmuxNextDesign

/// The Chief Settings card's Vault section (cmux issue 34263, building on 26412): the names of the
/// credentials this Mac keeps for the Chief and its agents, never a value. The app reads them off the
/// main thread each time the card opens. A name cmux made for itself (a cached provider sign-in,
/// `CLAUDE_TRANSFER_<hash>`) shows by what it is, "Claude sign-in", never as that name (cmux issue 38140).
@MainActor
public final class HomeChiefVaultSection: NSStackView {
    /// Reads the saved names (sorted, each once); nil when the vault's index cannot be read.
    public var names: (@Sendable () async -> [String]?)? {
        didSet { if isOpen { open() } else { isHidden = names == nil } }
    }

    var onResize: () -> Void = {}
    private(set) var shown: [String]?? = .none
    private var isOpen = false
    private var read: Task<Void, Never>?
    let summary = ThemedLabel(wrappingLabelWithString: "")

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space2
        setAccessibilityIdentifier("cmux.home.chief.vault")
        let width = HomeChiefSettingsView.width - 2 * HomeChiefSettingsView.inset
        summary.font = Typography.body
        summary.preferredMaxLayoutWidth = width
        summary.setAccessibilityIdentifier("cmux.home.chief.vault.names")
        let note = HomeChiefSettingsView.footnote(HomeEngineStrings.vaultNote)
        note.preferredMaxLayoutWidth = width
        for view in [HomeChiefSettingsView.sectionHeader(HomeEngineStrings.vaultSection), summary, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func open() {
        isOpen = true
        read?.cancel()
        guard let names else {
            isHidden = true
            return
        }
        isHidden = false
        // task-owner: the open card's one read of the vault's index; cancelled when the card closes
        read = Task { [weak self] in
            let found = await names()
            guard !Task.isCancelled else { return }
            self?.show(found)
        }
    }

    func close() {
        isOpen = false
        read?.cancel()
        read = nil
    }

    func show(_ names: [String]?) {
        let before = summary.stringValue
        shown = .some(names)
        summary.stringValue = switch names {
        case nil: HomeEngineStrings.vaultUnreadable
        case let names? where names.isEmpty: HomeEngineStrings.vaultEmpty
        case let names?: Self.listing(of: Self.shownNames(names))
        }
        if summary.stringValue != before { onResize() }
    }

    /// "2 saved: A, B" for the names the section lists.
    private static func listing(of shown: [String]) -> String {
        HomeEngineStrings.vaultNames(shown.count, shown.joined(separator: ", "))
    }

    /// What the section lists for the vault's `names`: a name the person set as it is, a sign-in cmux
    /// keeps by its provider, each once, sorted.
    static func shownNames(_ names: [String]) -> [String] {
        Set(names.map { name in
            CloudMachineSecrets.signInProvider(ofName: name).map(HomeEngineStrings.vaultSignIn) ?? name
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
