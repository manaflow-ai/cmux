import AppKit
import Foundation

/// Presents the "New Workspace" dialog with directory picker and template selection.
/// Returns the user's choices, or nil if cancelled.
@MainActor
enum NewWorkspaceDialog {

    struct Result {
        let directory: String
        let templateName: String?
    }

    /// Shows the new-workspace dialog. Returns nil if cancelled.
    static func run() -> Result? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(
            localized: "newWorkspaceDialog.open",
            defaultValue: "Open"
        )
        panel.message = String(
            localized: "newWorkspaceDialog.message",
            defaultValue: "Choose a directory for the new workspace."
        )

        let templates = TemplateRepository.shared.listTemplates()
        let accessory = buildAccessoryView(templates: templates)

        panel.accessoryView = accessory.container
        panel.isAccessoryViewDisclosed = true

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        let selectedIndex = accessory.popup.indexOfSelectedItem
        let templateName: String? = selectedIndex == 0 ? nil : templates[selectedIndex - 1]

        return Result(directory: url.path, templateName: templateName)
    }

    // MARK: - Private

    private struct AccessoryViews {
        let container: NSView
        let popup: NSPopUpButton
    }

    private static func buildAccessoryView(templates: [String]) -> AccessoryViews {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 36))

        let label = NSTextField(labelWithString: String(
            localized: "newWorkspaceDialog.templateLabel",
            defaultValue: "Template:"
        ))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItem(withTitle: String(
            localized: "newWorkspaceDialog.noTemplate",
            defaultValue: "None (plain terminal)"
        ))
        for template in templates {
            popup.addItem(withTitle: template)
        }
        container.addSubview(popup)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        return AccessoryViews(container: container, popup: popup)
    }
}
