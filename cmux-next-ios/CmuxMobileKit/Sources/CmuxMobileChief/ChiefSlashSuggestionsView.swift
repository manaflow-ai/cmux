#if os(iOS)
import Observation
import UIKit

/// The composer's `/` list (``ChiefSlashMenu``): a card above the message
/// field, one row per matching skill (`/name`, its description, where it
/// comes from), scrolling past about five rows. Tapping a row picks it. While
/// the list is on its way it says so, and it says when nothing matches, so a
/// typed `/` never shows nothing.
final class ChiefSlashSuggestionsView: UIView {
    /// A row was tapped.
    var onPick: ((ChiefSlashSkill) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var shown: [ChiefSlashSkill] = []
    private var shownStatus: String?

    /// The most the card asks for: five rows and half of the sixth, so a
    /// longer list reads as scrollable.
    static let maxRows: CGFloat = 5.5
    static let rowHeight: CGFloat = 56

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "chief.slash.suggestions"
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        // The card is a container: XCUI and VoiceOver find it and its rows.
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = true
        scroll.layer.cornerRadius = 16
        scroll.layer.cornerCurve = .continuous
        scroll.alwaysBounceVertical = false
        stack.axis = .vertical
        addSubview(scroll)
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
    }

    /// The height the card asks for at the shown rows.
    var preferredHeight: CGFloat {
        let rows = CGFloat(max(1, shown.count))
        return min(rows, Self.maxRows) * Self.rowHeight
    }

    /// Shows `skills`, or `status` (loading, failed, no match) when there are none.
    func configure(skills: [ChiefSlashSkill], status: String?, loading: Bool) {
        guard skills != shown || status != shownStatus || stack.arrangedSubviews.isEmpty else { return }
        shown = skills
        shownStatus = status
        for row in stack.arrangedSubviews { row.removeFromSuperview() }
        if skills.isEmpty {
            stack.addArrangedSubview(statusRow(status ?? "", loading: loading))
        } else {
            for (index, skill) in skills.enumerated() {
                stack.addArrangedSubview(row(skill, last: index == skills.count - 1))
            }
        }
        scroll.contentOffset = .zero
    }

    private func row(_ skill: ChiefSlashSkill, last: Bool) -> UIView {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "chief.slash.row./\(skill.name)"
        button.accessibilityLabel = "/\(skill.name), \(skill.description)"
        button.contentHorizontalAlignment = .fill
        let name = UILabel()
        name.text = "/" + skill.name
        name.font = .preferredFont(forTextStyle: .headline)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.lineBreakMode = .byTruncatingTail
        let source = UILabel()
        source.text = skill.sourceLabel
        source.font = .preferredFont(forTextStyle: .caption1)
        source.adjustsFontForContentSizeCategory = true
        source.textColor = .tertiaryLabel
        source.setContentCompressionResistancePriority(.required, for: .horizontal)
        source.setContentHuggingPriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [name, source])
        top.spacing = 8
        let summary = UILabel()
        summary.text = skill.description
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.adjustsFontForContentSizeCategory = true
        summary.textColor = .secondaryLabel
        summary.lineBreakMode = .byTruncatingTail
        let column = UIStackView(arrangedSubviews: [top, summary])
        column.axis = .vertical
        column.spacing = 1
        column.isUserInteractionEnabled = false
        button.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight),
        ])
        if !last {
            let rule = UIView()
            rule.backgroundColor = .separator
            rule.isUserInteractionEnabled = false
            button.addSubview(rule)
            rule.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
                rule.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                rule.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                rule.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            ])
        }
        button.addAction(UIAction { [weak self] _ in self?.onPick?(skill) }, for: .touchUpInside)
        return button
    }

    private func statusRow(_ text: String, loading: Bool) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        var items: [UIView] = []
        if loading {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            items.append(spinner)
        }
        items.append(label)
        let line = UIStackView(arrangedSubviews: items)
        line.spacing = 8
        line.alignment = .center
        let row = UIView()
        row.accessibilityIdentifier = "chief.slash.status"
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        row.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
        return row
    }
}

extension ChiefConversationContainer {
    /// `/` in the message field opens the list (``ChiefSlashSuggestionsView``):
    /// it follows the field's text, filters as more is typed, and a tap puts
    /// `/name ` in the field for the skill's input. The Mac's Chief host runs
    /// the skill when the message arrives (optchat-chief slash_skills.rs).
    func installSlashSuggestions() {
        slashSuggestions.isHidden = true
        slashSuggestions.onPick = { [weak self] skill in self?.pickSlashSkill(skill) }
        view.addSubview(slashSuggestions)
        NotificationCenter.default.addObserver(self, selector: #selector(composerTextChanged(_:)),
                                               name: UITextView.textDidChangeNotification, object: nil)
        observeSlashSkills()
    }

    @objc private func composerTextChanged(_ note: Notification) {
        guard let field = note.object as? UITextView, field === composerTextView else { return }
        updateSlashSuggestions()
    }

    /// The list redraws when the skills land (the engine report changes).
    private func observeSlashSkills() {
        withObservationTracking {
            _ = session.slashSkillList
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateSlashSuggestions()
                self?.observeSlashSkills()
            }
        }
    }

    /// Shows, filters or hides the list for the field's text and caret.
    func updateSlashSuggestions() {
        guard let field = composerTextView, field.markedTextRange == nil,
              field.selectedRange.length == 0,
              let menu = ChiefSlashMenu(text: field.text ?? "", caret: field.selectedRange.location) else {
            slashSuggestions.isHidden = true
            return
        }
        // A fresh `/` (the card was closed) may ask the Mac again; typing more never does.
        let fresh = slashSuggestions.isHidden
        let list = session.slashSkillList
        let skills: [ChiefSlashSkill]
        let status: String?
        var loading = false
        switch list {
        case .none:
            slashSuggestions.isHidden = true
            return
        case .loading:
            if fresh { session.loadSlashSkillsIfNeeded() }
            skills = []
            loading = true
            status = String(localized: "mobile.chief.slash.loading", defaultValue: "Loading skills…", bundle: .module)
        case .failed:
            if fresh { session.loadSlashSkillsIfNeeded() }
            skills = []
            if session.slashSkillsLoading {
                loading = true
                status = String(localized: "mobile.chief.slash.loading", defaultValue: "Loading skills…", bundle: .module)
            } else {
                status = String(localized: "mobile.chief.slash.failed", defaultValue: "Couldn't load skills from your Mac", bundle: .module)
            }
        case let .loaded(all):
            skills = menu.matches(all)
            if skills.isEmpty, all.isEmpty {
                status = String(localized: "mobile.chief.slash.none", defaultValue: "Chief has no skills yet", bundle: .module)
            } else if skills.isEmpty {
                // A typed command no skill matches is a plain message (`/tmp/x is broken`): no card.
                slashSuggestions.isHidden = true
                return
            } else {
                status = nil
            }
        }
        slashSuggestions.configure(skills: skills, status: status, loading: loading)
        let frame = field.convert(field.bounds, to: view)
        let width = max(200, view.bounds.width - 16)
        let height = slashSuggestions.preferredHeight
        // Above the field, under the header: the card takes the room between them, and hides
        // when not even one row fits there (it never covers the field).
        let header = conversation.view.convert(CGPoint(x: 0, y: conversation.headerMaxY), to: view).y
        // Under the header and under Chief's question bar when it shows (the card never cuts it).
        let ceiling = max(view.safeAreaInsets.top, header, slashCeilingBelowQuestionBar) + 8
        let top = max(ceiling, frame.minY - 12 - height)
        let room = frame.minY - 12 - top
        guard room >= Self.minSlashHeight else {
            slashSuggestions.isHidden = true
            return
        }
        slashSuggestions.frame = CGRect(x: 8, y: top, width: width, height: room)
        view.bringSubviewToFront(slashSuggestions)
        slashSuggestions.isHidden = false
    }

    private static var minSlashHeight: CGFloat { ChiefSlashSuggestionsView.rowHeight }

    private func pickSlashSkill(_ skill: ChiefSlashSkill) {
        guard let field = composerTextView,
              let menu = ChiefSlashMenu(text: field.text ?? "", caret: field.selectedRange.location) else { return }
        let (text, caret) = menu.applied(skill, to: field.text ?? "")
        field.text = text
        field.selectedRange = NSRange(location: caret, length: 0)
        // The composer follows its field through the delegate (send button, height).
        field.delegate?.textViewDidChange?(field)
        slashSuggestions.isHidden = true
        if !field.isFirstResponder { field.becomeFirstResponder() }
    }
}
#endif
