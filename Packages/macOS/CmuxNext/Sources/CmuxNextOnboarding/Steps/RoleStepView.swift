import AppKit
import CmuxNextDesign

/// Role: the roles in a three-column grid of radio cells (`RoleCell`), a
/// field for work the grid does not name, and "Suggest personalized tasks".
final class RoleStepView: NSView, NSTextFieldDelegate {
    private let model: RoleStepModel
    private var cells: [OnboardingRole: RoleCell] = [:]
    private let other = NSTextField()
    private let suggest: NSButton
    private var loop: RenderLoop?

    init(model: RoleStepModel) {
        self.model = model
        suggest = OnboardingControl.checkbox(OnboardingStrings.roleSuggestTasks, target: nil, action: #selector(RoleStepView.suggestToggled(_:)))
        super.init(frame: .zero)
        suggest.target = self

        let roles = OnboardingRole.allCases
        let rows = stride(from: 0, to: roles.count, by: 3).map { start in
            (start..<min(start + 3, roles.count)).map { index -> NSView in
                let cell = RoleCell(title: OnboardingStrings.roleName(roles[index]), target: self, action: #selector(picked(_:)))
                cells[roles[index]] = cell
                return cell
            }
        }
        let grid = NSGridView(views: rows.map { $0 + Array(repeating: NSGridCell.emptyContentView, count: 3 - $0.count) })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        for column in 0..<grid.numberOfColumns { grid.column(at: column).width = 176 }
        // Cells fill their grid cell, so every hover fill is the same size.
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .fill }
        for column in 0..<grid.numberOfColumns { grid.column(at: column).xPlacement = .fill }

        other.translatesAutoresizingMaskIntoConstraints = false
        other.placeholderString = OnboardingStrings.roleDescribe
        other.font = OnboardingMetrics.bodyFont
        other.textColor = Palette.textPrimary
        other.drawsBackground = false
        other.bezelStyle = .roundedBezel
        other.focusRingType = .none
        other.lineBreakMode = .byTruncatingTail
        other.delegate = self

        for view in [grid, other, suggest] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.topAnchor.constraint(equalTo: topAnchor),
            other.leadingAnchor.constraint(equalTo: leadingAnchor), other.trailingAnchor.constraint(equalTo: trailingAnchor),
            other.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            suggest.leadingAnchor.constraint(equalTo: leadingAnchor),
            suggest.topAnchor.constraint(equalTo: other.bottomAnchor, constant: 16),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        guard let role = cells.first(where: { $0.value.radio === sender })?.key else { return }
        model.select(role)
    }

    @objc private func suggestToggled(_ sender: NSButton) {
        model.suggestTasks = sender.state == .on
    }

    func controlTextDidChange(_ notification: Notification) {
        model.describe(other.stringValue)
    }

    private func render() {
        for (role, cell) in cells { cell.setOn(role == model.role) }
        if other.stringValue != model.otherRole { other.stringValue = model.otherRole }
        suggest.state = model.suggestTasks ? .on : .off
    }
}
