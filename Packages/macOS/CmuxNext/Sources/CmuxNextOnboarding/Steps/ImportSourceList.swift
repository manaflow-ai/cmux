import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The detected browsers, each with its profiles as check rows. Safari
/// without Full Disk Access shows why and a link instead of rows.
final class ImportSourceList: NSView {
    private let model: ImportStepModel
    private let stack = NSStackView()
    private var checks: [String: CheckRowView] = [:]
    private var shownSources: [BrowserSource] = []
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let phase = model.phase
        let sources = model.sources
        if sources != shownSources || stack.arrangedSubviews.isEmpty {
            shownSources = sources
            rebuild(sources, detecting: phase == .detecting)
        }
        let editable = model.canEditSelection
        for (id, row) in checks {
            row.isChecked = model.selectedProfiles.contains(id)
            row.isEnabled = editable && row.hasData
        }
    }

    private func rebuild(_ sources: [BrowserSource], detecting: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        checks = [:]
        guard !sources.isEmpty else {
            let text = detecting || model.phase == .idle ? OnboardingStrings.detecting : OnboardingStrings.noBrowsers
            stack.addArrangedSubview(OnboardingLabel.make(text, font: Typography.body, color: Palette.textTertiary))
            return
        }
        for source in sources {
            let header = SourceHeaderView(source: source)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(Metrics.space2, after: header)
            if source.needsFullDiskAccess {
                let notice = FullDiskAccessNotice(model: model)
                stack.addArrangedSubview(notice)
                notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                for profile in source.profiles {
                    let kinds = profile.importableKinds.filter(ImportStepModel.offeredKinds.contains)
                    let caption = kinds.isEmpty ? OnboardingStrings.nothingToImport
                        : ListFormatter.localizedString(byJoining: kinds.map(OnboardingStrings.kind))
                    let title = source.browser.family == .safari ? source.browser.displayName : profile.displayName
                    let row = CheckRowView(title: title, caption: caption, hasData: !kinds.isEmpty)
                    row.onToggle = { [weak model] in model?.toggle(profile) }
                    checks[profile.id] = row
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Metrics.space6, after: last) }
        }
    }
}

/// App icon and name.
final class SourceHeaderView: NSStackView {
    init(source: BrowserSource) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = source.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        let side = Metrics.iconSize + Metrics.space2
        icon.widthAnchor.constraint(equalToConstant: side).isActive = true
        icon.heightAnchor.constraint(equalToConstant: side).isActive = true
        let name = OnboardingLabel.make(source.browser.displayName, font: Typography.header, color: Palette.textSecondary)
        setViews([icon, name], in: .leading)
        spacing = Metrics.space3
        edgeInsets = NSEdgeInsets(top: 0, left: Metrics.space3, bottom: 0, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A document view that lays out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
