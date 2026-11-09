public import AppKit
import CmuxNextCloud
import CmuxNextDesign
public import CmuxNextWakeups

/// The Chief Settings card's Vault section (cmux issue 34263, building on 26412): the names of the
/// credentials this Mac keeps for the Chief and its agents, never a value. The app reads them off the
/// main thread each time the card opens.
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
        case let names?: HomeEngineStrings.vaultNames(names.count, names.joined(separator: ", "))
        }
        if summary.stringValue != before { onResize() }
    }
}

extension HomeChiefVaultSection {
    /// Reads the names in this Mac's Cloud secrets index (`~/.config/cmux/cloud-secrets.json`) on
    /// `work`, off the main thread; nil when the index cannot be read.
    public static func keychainNames(work: BackgroundWork) -> @Sendable () async -> [String]? {
        {
            let index = try? await work.run(.userVisible, mayBlock: .files) { CloudMachineSecrets.read(CloudMachineSecrets.indexURL().path) }
            return index.flatMap(CloudMachineSecrets.index(from:)).map(CloudMachineSecrets.names(in:))
        }
    }
}
