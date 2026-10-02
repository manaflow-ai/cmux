import AppKit
import CmuxNextDesign

/// First task: two cards side by side and where the task runs. Picking one
/// swaps them for the task's live agent chat (the App's view) with the
/// files it saved underneath, each with Open and Show in Finder.
final class FirstTaskStepView: NSView {
    private let model: FirstTaskStepModel
    private let services: any OnboardingServices
    private let cards = NSStackView()
    private let caption = OnboardingLabel.make("", font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private let chatFrame = ThemedView()
    private let saved = NSStackView()
    private var chat: NSView?
    private var shownOutputs: [URL] = []
    private var chatBottom: NSLayoutConstraint?
    private var loop: RenderLoop?

    /// Rows shown under the chat; the newest files first.
    private static let maxRows = 3

    init(model: FirstTaskStepModel, services: any OnboardingServices) {
        self.model = model
        self.services = services
        super.init(frame: .zero)

        cards.translatesAutoresizingMaskIntoConstraints = false
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        for task in FirstTask.allCases {
            cards.addArrangedSubview(FirstTaskCard(symbol: Self.symbol(task), title: OnboardingStrings.firstTaskName(task),
                                                   detail: OnboardingStrings.firstTaskDetail(task)) { [weak model] in model?.pick(task) })
        }
        caption.stringValue = OnboardingStrings.firstTaskWhere

        chatFrame.cornerRadius = OnboardingMetrics.previewCornerRadius
        chatFrame.border = { Palette.separator }
        chatFrame.layer?.masksToBounds = true
        chatFrame.isHidden = true

        saved.translatesAutoresizingMaskIntoConstraints = false
        saved.orientation = .vertical
        saved.alignment = .leading
        saved.spacing = 2
        saved.isHidden = true

        for view in [cards, caption, chatFrame, saved] as [NSView] { addSubview(view) }
        let chatBottom = chatFrame.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.chatBottom = chatBottom
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: topAnchor),
            cards.leadingAnchor.constraint(equalTo: leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            chatFrame.topAnchor.constraint(equalTo: topAnchor),
            chatFrame.leadingAnchor.constraint(equalTo: leadingAnchor),
            chatFrame.trailingAnchor.constraint(equalTo: trailingAnchor),
            chatBottom,
            saved.leadingAnchor.constraint(equalTo: leadingAnchor),
            saved.trailingAnchor.constraint(equalTo: trailingAnchor),
            saved.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ task: FirstTask) -> String {
        switch task {
        case .note: "note.text"
        case .chart: "chart.bar.xaxis"
        }
    }

    private func render() {
        let picked = model.task != nil
        cards.isHidden = picked
        if picked, chat == nil, let prompt = model.prompt {
            showChat(prompt: prompt)
        }
        if let failure = model.failure { caption.stringValue = failure }
        caption.isHidden = picked && chat != nil
        renderOutputs()
    }

    private func showChat(prompt: String) {
        guard let view = services.makeFirstTaskView(cwd: model.folder.url, prompt: prompt) else {
            caption.stringValue = OnboardingStrings.firstTaskNoAgent
            caption.isHidden = false
            return
        }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        chatFrame.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: chatFrame.topAnchor),
            view.leadingAnchor.constraint(equalTo: chatFrame.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: chatFrame.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: chatFrame.bottomAnchor),
        ])
        chatFrame.isHidden = false
        chat = view
    }

    /// Rebuilds the saved-file rows when the list changed; the chat gives
    /// up the rows' height only once there is a file.
    private func renderOutputs() {
        let files = Array(model.outputs.prefix(Self.maxRows))
        guard files != shownOutputs else { return }
        shownOutputs = files
        for view in saved.arrangedSubviews { view.removeFromSuperview() }
        if !files.isEmpty {
            saved.addArrangedSubview(OnboardingLabel.make(OnboardingStrings.firstTaskSaved, font: OnboardingMetrics.captionFont, color: Palette.textSecondary))
            for file in files {
                let row = OutputFileRow(file: file, onOpen: { [weak model] in model?.open($0) }, onReveal: { [weak model] in model?.reveal($0) })
                saved.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: saved.widthAnchor).isActive = true
            }
        }
        saved.isHidden = files.isEmpty
        chatBottom?.isActive = false
        chatBottom = files.isEmpty
            ? chatFrame.bottomAnchor.constraint(equalTo: bottomAnchor)
            : chatFrame.bottomAnchor.constraint(equalTo: saved.topAnchor, constant: -8)
        chatBottom?.isActive = true
    }
}
