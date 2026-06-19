import AppKit
import Foundation

extension MenuBarProfilingProgressWindowController {
    func configureEmailField() {
        emailField.placeholderString = String(localized: "statusMenu.profiling.emailPlaceholder", defaultValue: "you@example.com")
        emailField.stringValue = UserDefaults.standard.string(forKey: feedbackSettings.storedEmailKey) ?? ""
        emailField.delegate = self
        emailField.controlSize = .large
        emailField.font = .systemFont(ofSize: 13)
        emailErrorLabel.font = .systemFont(ofSize: 12)
        emailErrorLabel.textColor = .systemRed
        emailErrorLabel.isHidden = true
    }

    func configureTextView(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = editable ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
    }

    func labeledView(label: String, view: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [labelView, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    func scrollView(for textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scrollView
    }

    func permissionBox() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.contentViewMargins = NSSize(width: 12, height: 10)
        let title = NSTextField(labelWithString: String(localized: "statusMenu.profiling.permissionTitle", defaultValue: "Why macOS may ask for permission"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NSStackView(views: [title, permissionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        return box
    }
}

extension MenuBarProfilingProgressWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updatePreview()
        updateSubmitState()
    }
}
