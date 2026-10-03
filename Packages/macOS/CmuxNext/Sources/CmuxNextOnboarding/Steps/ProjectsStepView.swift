import AppKit
import CmuxNextDesign

/// Projects: the folders the agents worked in (`ProjectRow`, the best
/// checked), one line naming the privacy-guarded folders macOS will ask
/// about, and, only when nothing was found, a folder picker. A folder
/// dropped anywhere on the step joins the list, checked.
final class ProjectsStepView: NSView {
    private let model: ProjectsStepModel
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private let empty = NSStackView()
    private var rows: [String: ProjectRow] = [:]
    private var shown: [AgentProject]?
    private var listHeight: NSLayoutConstraint?
    private var loop: RenderLoop?

    init(model: ProjectsStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let choose = OnboardingControl.button(OnboardingStrings.projectsChoose, target: self, action: #selector(choosePressed))
        let hint = OnboardingLabel.make(OnboardingStrings.projectsDropHint, font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
        empty.setViews([OnboardingLabel.make(OnboardingStrings.projectsEmpty, color: Palette.textSecondary), choose, hint], in: .leading)
        empty.orientation = .vertical
        empty.alignment = .leading
        empty.spacing = 10
        empty.isHidden = true
        let stack = NSStackView(views: [scroll, empty, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight?.isActive = true
        registerForDraggedTypes([.fileURL])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func choosePressed() { model.chooseFolder() }

    private func render() {
        let projects = model.projects
        if projects != shown {
            shown = projects
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows = [:]
            let now = Date()
            for project in projects {
                let row = ProjectRow(project: project, home: model.homeDirectory, now: now) { [weak model] in model?.toggle(project) }
                rows[project.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        for project in projects { rows[project.id]?.update(checked: model.isSelected(project)) }
        // As tall as the rows, up to five and a half: the half row says the list scrolls.
        listHeight?.constant = min(CGFloat(projects.count), 5.5) * ProjectRow.height + 4
        let nothing = model.scanned && projects.isEmpty
        scroll.isHidden = nothing
        empty.isHidden = !nothing
        let guarded = model.privacyFolders
        if model.isScanning {
            status.stringValue = OnboardingStrings.projectsScanning
        } else {
            status.stringValue = guarded.isEmpty ? "" : OnboardingStrings.projectsPrivacy(guarded)
        }
    }

    // A dropped folder joins the list.

    private func folders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(sender).isEmpty ? [] : .link
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = folders(sender)
        dropped.forEach(model.add)
        return !dropped.isEmpty
    }
}
