import OSLog
import UIKit

@MainActor
final class WorkspaceDetailViewController: UIViewController {
    private let logger = Logger(subsystem: "ai.manaflow.KeyboardPinningLab", category: "Keyboard")
    private let terminalView = TerminalCanvasView()
    private let dockView = ComposerDockView()
    private let headerView = WorkspaceHeaderView()
    private var stressTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureKeyboardPinning()
        configureActions()
        observeKeyboardFrames()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dockView.focusComposer()

        if UserDefaults.standard.bool(forKey: "stressKeyboard") {
            runStressSequence()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stressTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let guideTop = view.keyboardLayoutGuide.layoutFrame.minY
        let dockBottom = dockView.frame.maxY
        let gap = guideTop - dockBottom
        headerView.updatePinGap(gap)
    }

    private func configureHierarchy() {
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.082, alpha: 1)
        [headerView, terminalView, dockView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 60),

            terminalView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: dockView.topAnchor),

            dockView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureKeyboardPinning() {
        let keyboardGuide = view.keyboardLayoutGuide
        keyboardGuide.followsUndockedKeyboard = true

        // The dock and keyboard share one UIKit constraint graph. UIKit owns the
        // keyboard's presentation frame and interruptible animation, so no copied
        // keyboard height or separately-timed animation can diverge.
        dockView.bottomAnchor.constraint(equalTo: keyboardGuide.topAnchor).isActive = true
    }

    private func configureActions() {
        terminalView.onTap = { [weak self] in
            self?.dockView.focusComposer()
        }
        dockView.onKeyboardToggle = { [weak self] in
            self?.toggleKeyboard()
        }
        headerView.onStress = { [weak self] in
            self?.runStressSequence()
        }
    }

    private func observeKeyboardFrames() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            self.logger.debug("Keyboard target minY: \(frame.minY, format: .fixed(precision: 1))")
        }
    }

    private func toggleKeyboard() {
        if dockView.isComposerFocused {
            dockView.dismissComposer()
        } else {
            dockView.focusComposer()
        }
    }

    private func runStressSequence() {
        stressTask?.cancel()
        stressTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                guard !Task.isCancelled else { return }
                self.toggleKeyboard()
                try? await Task.sleep(for: .milliseconds(135))
            }
            guard !Task.isCancelled else { return }
            self.dockView.focusComposer()
        }
    }
}

private final class WorkspaceHeaderView: UIView {
    var onStress: (() -> Void)?

    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.082, alpha: 0.98)

        let backButton = Self.symbolButton("chevron.left")
        let titleLabel = UILabel()
        titleLabel.text = String(localized: "workspace.title", defaultValue: "cmux DEV lab")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white

        let terminalButton = Self.symbolButton("rectangle.on.rectangle")
        let stressButton = Self.symbolButton("arrow.trianglehead.2.clockwise.rotate.90")
        stressButton.accessibilityIdentifier = "stressKeyboard"
        stressButton.accessibilityLabel = String(localized: "stress.accessibility", defaultValue: "Rapidly toggle keyboard 20 times")
        stressButton.addAction(UIAction { [weak self] _ in self?.onStress?() }, for: .touchUpInside)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = UIColor(red: 0.31, green: 0.84, blue: 0.53, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "pinGapStatus"

        let row = UIStackView(arrangedSubviews: [backButton, titleLabel, UIView(), statusLabel, stressButton, terminalButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 105),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updatePinGap(_ gap: CGFloat) {
        let clamped = abs(gap) < 0.05 ? 0 : gap
        let formattedGap = Double(clamped).formatted(.number.precision(.fractionLength(1)))
        statusLabel.text = String(localized: "PIN GAP \(formattedGap) pt")
        statusLabel.textColor = abs(clamped) < 0.1 ? UIColor(red: 0.31, green: 0.84, blue: 0.53, alpha: 1) : .systemRed
    }

    private static func symbolButton(_ symbol: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = .white
        return UIButton(configuration: configuration)
    }
}

private final class TerminalCanvasView: UIView {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.105, green: 0.108, blue: 0.112, alpha: 1)
        isAccessibilityElement = true
        accessibilityIdentifier = "terminalCanvas"
        accessibilityLabel = String(localized: "terminal.accessibility", defaultValue: "Terminal. Tap to show keyboard.")

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)

        let terminalText = UILabel()
        terminalText.translatesAutoresizingMaskIntoConstraints = false
        terminalText.numberOfLines = 0
        terminalText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        terminalText.textColor = UIColor(white: 0.79, alpha: 1)
        terminalText.text = String(localized: "terminal.sample", defaultValue: "Last login: Fri Aug 7 19:45:12 on ttys006\n\n~/cmux  git:(feat/keyboard-pinning-lab)\n❯")
        addSubview(terminalText)

        NSLayoutConstraint.activate([
            terminalText.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            terminalText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            terminalText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() {
        onTap?()
    }
}

private final class ComposerDockView: UIView, UITextFieldDelegate {
    var onKeyboardToggle: (() -> Void)?

    private let textField = UITextField()

    var isComposerFocused: Bool { textField.isFirstResponder }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.082, alpha: 0.99)

        let shortcuts = makeShortcutBar()
        let composer = makeComposerBar()
        let stack = UIStackView(arrangedSubviews: [shortcuts, composer])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            shortcuts.heightAnchor.constraint(equalToConstant: 36),
            composer.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func focusComposer() {
        textField.becomeFirstResponder()
    }

    func dismissComposer() {
        textField.resignFirstResponder()
    }

    private func makeShortcutBar() -> UIView {
        let specs: [(String, String)] = [
            ("keyboard", "keyboard.toggle"),
            ("circle.fill", "shortcut.control"),
            ("square.and.pencil", "shortcut.command"),
            ("chevron.up", "shortcut.up"),
            ("option", "shortcut.option"),
            ("command", "shortcut.command"),
            ("doc.on.clipboard", "shortcut.paste"),
        ]

        let buttons = specs.map { symbol, identifier in
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.baseForegroundColor = .white
            configuration.contentInsets = .zero
            let button = UIButton(configuration: configuration)
            button.accessibilityIdentifier = identifier
            if identifier == "keyboard.toggle" {
                button.addAction(UIAction { [weak self] _ in self?.onKeyboardToggle?() }, for: .touchUpInside)
            }
            return button
        }

        var tabConfiguration = UIButton.Configuration.filled()
        tabConfiguration.title = String(localized: "shortcut.tab", defaultValue: "Tab")
        tabConfiguration.baseBackgroundColor = UIColor(white: 0.18, alpha: 1)
        tabConfiguration.baseForegroundColor = .white
        tabConfiguration.cornerStyle = .capsule
        tabConfiguration.contentInsets = .init(top: 0, leading: 2, bottom: 0, trailing: 2)
        tabConfiguration.titleLineBreakMode = .byClipping
        tabConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 11, weight: .medium)
            return attributes
        }
        let tabButton = UIButton(configuration: tabConfiguration)

        var escapeConfiguration = tabConfiguration
        escapeConfiguration.title = String(localized: "shortcut.escape", defaultValue: "Esc")
        let escapeButton = UIButton(configuration: escapeConfiguration)

        let stack = UIStackView(arrangedSubviews: buttons + [tabButton, escapeButton])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 4
        return stack
    }

    private func makeComposerBar() -> UIView {
        let attachment = Self.circleButton(symbol: "paperclip")
        let microphone = Self.circleButton(symbol: "mic")
        let send = Self.circleButton(symbol: "arrow.up", filled: true)

        textField.delegate = self
        textField.placeholder = String(localized: "composer.placeholder", defaultValue: "Message")
        textField.textColor = .white
        textField.tintColor = .white
        textField.font = .preferredFont(forTextStyle: .body)
        textField.returnKeyType = .send
        textField.autocorrectionType = .no
        textField.accessibilityIdentifier = "composerTextField"

        let fieldContainer = UIView()
        fieldContainer.backgroundColor = UIColor(white: 0.12, alpha: 1)
        fieldContainer.layer.cornerRadius = 17
        textField.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -8),
            textField.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            textField.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
        ])

        let row = UIStackView(arrangedSubviews: [attachment, microphone, fieldContainer, send])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 6
        return row
    }

    private static func circleButton(symbol: String, filled: Bool = false) -> UIButton {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = filled ? .black : .white
        configuration.baseBackgroundColor = filled ? UIColor(white: 0.85, alpha: 1) : .clear
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        return UIButton(configuration: configuration)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.text = nil
        return false
    }
}
