import AppKit

@MainActor
final class WorkspaceActionSaveDialogAccessory {
    let view: NSView
    let nameField: NSTextField
    let makeDefaultCheckbox: NSButton

    init(snapshot: WorkspaceConfigActionSnapshot, initialName: String) {
        nameField = NSTextField()
        nameField.stringValue = initialName
        nameField.placeholderString = String(
            localized: "dialog.saveWorkspaceLayout.namePlaceholder",
            defaultValue: "Layout name"
        )
        nameField.translatesAutoresizingMaskIntoConstraints = false

        makeDefaultCheckbox = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.saveWorkspaceLayout.makeDefaultCheckbox",
                defaultValue: "Use as default for new workspaces"
            ),
            target: nil,
            action: nil
        )
        makeDefaultCheckbox.state = .off
        makeDefaultCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(makeDefaultCheckbox)

        Self.addDisclosureSections(snapshot: snapshot, to: stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 420),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            makeDefaultCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
        view = root
    }

    private static func addDisclosureSections(
        snapshot: WorkspaceConfigActionSnapshot,
        to stack: NSStackView
    ) {
        addSection(
            header: String(
                localized: "dialog.saveWorkspaceLayout.commandsHeader",
                defaultValue: "Commands that will be saved and re-run:"
            ),
            items: snapshot.capturedCommands,
            to: stack
        )
        addSection(
            header: String(
                localized: "dialog.saveWorkspaceLayout.urlsHeader",
                defaultValue: "URLs that will be saved:"
            ),
            items: snapshot.capturedURLs,
            to: stack
        )
        addSection(
            header: String(
                localized: "dialog.saveWorkspaceLayout.envHeader",
                defaultValue: "Environment variables whose values will be saved:"
            ),
            items: snapshot.capturedEnvironmentKeys,
            to: stack
        )
    }

    private static func addSection(header: String, items: [String], to stack: NSStackView) {
        guard !items.isEmpty else { return }
        let label = NSTextField(labelWithString: header)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)

        let scrollView = disclosureScrollView(text: items.joined(separator: "\n"))
        stack.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: disclosureHeight(for: scrollView)),
        ])
    }

    private static func disclosureScrollView(text: String) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 408, height: 1))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private static func disclosureHeight(for scrollView: NSScrollView) -> CGFloat {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return 48
        }
        textContainer.containerSize = NSSize(width: 408, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        return min(160, max(48, ceil(usedHeight + textView.textContainerInset.height * 2 + 4)))
    }
}
