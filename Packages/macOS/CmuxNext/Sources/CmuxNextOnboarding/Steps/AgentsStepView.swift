import AppKit
import CmuxNextDesign

/// The Agents step's body: a card per installed agent CLI (its mark, name and sign-in) with
/// Sign In on each one not signed in, then one line under the list. After a Sign In, the
/// window becoming key again reads the sign-ins again (`OnboardingModel.windowBecameKey`).
final class AgentsStepView: NSView {
    private let model: AgentsStepModel
    private let icons: (OnboardingAgent) -> NSImage?
    private let list = NSStackView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private var rows: [String: AgentSignInRow] = [:]
    private var shownIDs: [String]?
    private var loop: RenderLoop?

    init(model: AgentsStepModel, icons: @escaping (OnboardingAgent) -> NSImage?) {
        self.model = model
        self.icons = icons
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, status] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor), list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let agents = model.agents
        let ids = agents.map(\.id)
        if ids != shownIDs {
            shownIDs = ids
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            var next: [String: AgentSignInRow] = [:]
            for agent in agents {
                let row = rows[agent.id] ?? AgentSignInRow(id: agent.id, icon: icons(agent)) { [weak model] id in model?.signIn(id) }
                next[agent.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            rows = next
        }
        for agent in agents { rows[agent.id]?.update(agent) }
        let text: String? = if model.signInFailed {
            OnboardingStrings.agentsSignInFailed
        } else if !model.loaded {
            OnboardingStrings.agentsChecking
        } else if agents.isEmpty {
            OnboardingStrings.agentsNone
        } else if model.signingIn != nil {
            OnboardingStrings.agentsSignInRunning
        } else {
            nil
        }
        status.stringValue = text ?? ""
        status.isHidden = text == nil
    }
}

/// One agent in the Agents step: a rounded card with the agent's mark, its name, its sign-in
/// and, unless it is signed in, a Sign In capsule. The row keeps its size when that changes.
final class AgentSignInRow: NSView {
    static let height: CGFloat = 60
    private static let padding: CGFloat = 14
    static let iconSide: CGFloat = 24
    private let id: String
    private let onSignIn: (String) -> Void
    private let name = OnboardingLabel.make(font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis))
    private let auth = OnboardingLabel.make(font: Typography.system(size: TypeScale.body), color: Palette.textSecondary)
    private lazy var signIn = OnboardingCapsuleButton(title: OnboardingStrings.agentsSignIn, style: .plain, target: self, action: #selector(signInPressed))
    private let mark = NSImageView()
    private var loop: RenderLoop?

    init(id: String, icon: NSImage?, onSignIn: @escaping (String) -> Void) {
        self.id = id
        self.onSignIn = onSignIn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = OnboardingCardView(cornerRadius: 16)
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.image = icon ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let names = NSStackView(views: [name, auth])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        signIn.setAccessibilityIdentifier("cmux.onboarding.agents.signIn.\(id)")
        for view in [card, mark, names, signIn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let padding = Self.padding
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: Self.iconSide), mark.heightAnchor.constraint(equalToConstant: Self.iconSide),
            names.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: padding), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.trailingAnchor.constraint(lessThanOrEqualTo: signIn.leadingAnchor, constant: -padding),
            signIn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding), signIn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        loop = RenderLoop { [weak self] in
            _ = ThemeScope.app.store.input
            self?.applyColors()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The marks are template images: they take the theme's primary text color.
    private func applyColors() {
        performWithTheme { mark.contentTintColor = Palette.textPrimary }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ agent: OnboardingAgent) {
        if name.stringValue != agent.name {
            name.stringValue = agent.name
            signIn.setAccessibilityLabel(OnboardingStrings.agentsSignInNamed(agent.name))
        }
        auth.stringValue = OnboardingStrings.agentsAuth(agent.auth)
        signIn.isHidden = !agent.offersSignIn
    }

    @objc private func signInPressed() { onSignIn(id) }
}
