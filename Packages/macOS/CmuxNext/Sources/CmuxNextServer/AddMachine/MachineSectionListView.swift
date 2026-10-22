public import AppKit
import CmuxNextDesign

/// The Machines section: every machine with its link state and last check; New Workspace opens a
/// workspace on it (`workspace.newOnMachine`), Add Machine… opens the Add Machine card.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md). Rows take ``MachineSectionRow`` value snapshots
/// and the two actions only; ``show(_:)`` rebuilds them only when the rows change.
///
/// ```swift
/// let list = MachineSectionListView(newWorkspace: { id in open(id) }, addMachine: { add() })
/// list.show(model.rows)
/// ```
public final class MachineSectionListView: NSView {
    private let newWorkspace: @MainActor (String) -> Void
    private let addMachine: @MainActor () -> Void
    private let rowStack = NSStackView()
    private var rows: [MachineSectionRow]?

    /// Makes an empty section.
    ///
    /// - Parameters:
    ///   - newWorkspace: Opens a workspace on the machine with this id (a row's plus button).
    ///   - addMachine: Opens the Add Machine card.
    public init(newWorkspace: @escaping @MainActor (String) -> Void, addMachine: @escaping @MainActor () -> Void) {
        self.newWorkspace = newWorkspace
        self.addMachine = addMachine
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2

        let add = NSButton(title: AddMachineStrings.addMachine, image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(addClicked))
        add.isBordered = false
        add.imagePosition = .imageLeading
        add.font = Typography.body
        add.setAccessibilityIdentifier("cmux.rightSidebar.machines.addMachine")
        let addLine = NSStackView(views: [add])
        addLine.edgeInsets = NSEdgeInsets(top: 3, left: Metrics.panelInset, bottom: 3, right: Metrics.panelInset)

        let stack = NSStackView(views: [rowStack, addLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            rowStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override public var isFlipped: Bool { true }

    /// Shows `next`, one row per machine in order; does nothing when the rows did not change.
    public func show(_ next: [MachineSectionRow]) {
        guard next != rows else { return }
        rows = next
        for view in rowStack.arrangedSubviews { view.removeFromSuperview() }
        for row in next {
            let view = MachineSectionRowView(row: row, newWorkspace: newWorkspace)
            rowStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    @objc private func addClicked() { addMachine() }
}
