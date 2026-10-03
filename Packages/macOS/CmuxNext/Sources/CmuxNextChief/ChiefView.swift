public import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextHome
import Observation

/// Localized strings of the chief experiment.
public nonisolated enum ChiefStrings {
    public static var title: String {
        String(localized: "chief.title", defaultValue: "Chief (experiment)", bundle: .module)
    }

    static var connecting: String {
        String(localized: "chief.connecting", defaultValue: "Connecting to Chief…", bundle: .module)
    }

    static func notConfigured(_ path: String) -> String {
        String(localized: "chief.notConfigured", defaultValue: "Chief is not configured. Add \(path) with the Worker URL and token.",
               bundle: .module)
    }
}

/// One chief conversation in a tab: the shared Home store fed by
/// `ChiefHomeSource`, rendered by the shared native transcript. A label shows
/// until the first inbox arrives (the transcript needs `me` to be created).
@MainActor
public final class ChiefView: NSView {
    private let store: HomeStore?
    private let conversation: ConversationID?
    private let status = NSTextField(labelWithString: "")
    private var transcript: HomeNativeTranscriptView?
    private var binding: HomeStoreBinding?
    private var waitTask: Task<Void, Never>?

    /// Reads the experiment config; without one the view says where it goes.
    public init(config: ChiefExperimentConfig? = ChiefExperimentConfig.load()) {
        if let config {
            let source = ChiefHomeSource(config: config)
            store = HomeStore(source: source)
            conversation = source.conversation
        } else {
            store = nil
            conversation = nil
        }
        super.init(frame: .zero)
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 0
        addSubview(status)
        guard let store, let conversation else {
            status.stringValue = ChiefStrings.notConfigured(ChiefExperimentConfig.defaultFile.path(percentEncoded: false))
            return
        }
        status.stringValue = ChiefStrings.connecting
        store.start()
        // task-owner: this view (cancelled in close()); event-driven (Observation on store.me)
        waitTask = Task { [weak self] in
            for await me in Observations({ store.me }) {
                guard let self, let me else { continue }
                await store.open(conversation)
                self.showTranscript(me: me.id, store: store, conversation: conversation)
                return
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func showTranscript(me: ParticipantID, store: HomeStore, conversation: ConversationID) {
        guard transcript == nil else { return }
        let view = HomeNativeTranscriptView(conversation: conversation, me: me)
        addSubview(view)
        transcript = view
        binding = HomeStoreBinding(store: store, controller: view.controller)
        status.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(view)
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        transcript?.frame = bounds
        let size = status.sizeThatFits(CGSize(width: max(100, bounds.width - 64), height: .greatestFiniteMagnitude))
        status.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
    }

    /// The tab closed: stop the poll and the observation.
    public func close() {
        waitTask?.cancel()
        waitTask = nil
        binding?.stop()
        binding = nil
        store?.stop()
    }
}
