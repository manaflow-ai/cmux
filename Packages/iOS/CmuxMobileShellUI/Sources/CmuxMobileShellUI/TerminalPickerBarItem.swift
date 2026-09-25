#if os(iOS)
import CmuxMobileSupport
import UIKit

/// UIKit owns the image, hit area, glass, and menu presentation. The deferred
/// menu takes one snapshot when opened, so live title updates cannot move rows
/// while someone is choosing a terminal.
@MainActor
final class TerminalPickerBarItem {
    let button: UIBarButtonItem
    private var value: TerminalPickerMenuValue
    private var actions: TerminalPickerMenuActions

    init(value: TerminalPickerMenuValue, actions: TerminalPickerMenuActions) {
        self.value = value
        self.actions = actions
        button = UIBarButtonItem(image: UIImage(systemName: "rectangle.stack"), menu: nil)
        button.accessibilityIdentifier = "MobileTerminalDropdown"
        button.accessibilityLabel = L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")
        button.accessibilityValue = value.selectedName ?? ""
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuSections() ?? [])
        }])
    }

    func update(value: TerminalPickerMenuValue, actions: TerminalPickerMenuActions) {
        self.value = value
        self.actions = actions
        button.accessibilityValue = value.selectedName ?? ""
    }

    private func menuSections() -> [UIMenuElement] {
        let value = value
        let actions = actions
        #if DEBUG
        TerminalPickerMenuDiagnostics().recordContentBuilderEvaluation(rowCount: value.rows.count)
        #endif
        var sections = [UIMenu(
            title: L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"),
            options: .displayInline,
            children: value.terminalRows.map { row in
                action(row.name, image: "terminal",
                       id: "MobileTerminalMenuItem-\(row.terminalID?.rawValue ?? "")",
                       state: row.id == value.checkedRowID ? .on : .off) {
                    if let id = row.terminalID { actions.selectTerminal(id) }
                }
            }
        )]
        if !value.macSurfaceRows.isEmpty {
            sections.append(UIMenu(
                title: L10n.string("mobile.surface.section", defaultValue: "Mac Surfaces"),
                options: .displayInline,
                children: value.macSurfaceRows.map { row in
                    action(row.name, image: row.surfaceKind.systemImage,
                           id: "MobileMacSurfaceMenuItem-\(row.macSurfaceID?.rawValue ?? "")",
                           state: row.id == value.checkedRowID ? .on : .off) {
                        if let id = row.macSurfaceID { actions.selectMacSurface(id) }
                    }
                }
            ))
        }
        if value.supportsSimulatorStream, !value.simulatorStreamRows.isEmpty {
            sections.append(UIMenu(
                title: L10n.string("mobile.simulatorStream.menuTitle", defaultValue: "Mac Simulators"),
                options: .displayInline,
                children: value.simulatorStreamRows.map { row in
                    action(row.label,
                           image: row.id == value.activeSimulatorStreamPanelID ? "checkmark.circle.fill" : "iphone",
                           id: "SimulatorStreamMenuItem-\(row.id)") { actions.selectSimulatorStream(row.id) }
                }
            ))
        }
        let browserTitle = L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")
        if value.supportsBrowserStream {
            if !value.browserStreamRows.isEmpty {
                sections.append(UIMenu(title: browserTitle, options: .displayInline,
                                      children: value.browserStreamRows.map { row in
                    action(row.label,
                           image: row.id == value.activeBrowserStreamPanelID ? "checkmark.circle.fill" : "globe",
                           id: "BrowserStreamMenuItem-\(row.id)") { actions.selectBrowserStream(row.id) }
                }))
            }
        } else {
            sections.append(UIMenu(title: browserTitle, options: .displayInline, children: [
                action(L10n.string("mobile.macUpdateHint.browserStream", defaultValue: "Update cmux on your Mac to stream browser panes"),
                       image: "arrow.down.circle", id: "BrowserStreamMacUpdateHint", attributes: .disabled) {},
            ]))
        }
        sections.append(UIMenu(options: .displayInline, children: [
            action(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                   image: "plus.square.on.square", id: "MobileNewWorkspaceMenuItem",
                   attributes: value.canCreateWorkspace ? [] : .disabled, perform: actions.createWorkspace),
            action(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                   image: "plus", id: "MobileNewTerminalMenuItem", perform: actions.createTerminal),
            action(L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                   image: value.hasActiveBrowser ? "checkmark.circle.fill" : "globe",
                   id: "MobileNewBrowserMenuItem", perform: actions.openBrowser),
        ]))
        var utilities: [UIMenuElement] = []
        if !value.hasActiveBrowser {
            utilities.append(action(L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                                    image: "doc.plaintext", id: "MobileViewAsTextMenuItem", perform: actions.openTextSheet))
        }
        #if DEBUG
        utilities.append(action(L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                                image: "doc.on.clipboard", id: "MobileCopyDebugLogsMenuItem", perform: actions.copyDebugLogs))
        #endif
        utilities.append(action(L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                                image: "paperplane", id: "MobileSendFeedbackMenuItem", perform: actions.sendFeedback))
        sections.append(UIMenu(options: .displayInline, children: utilities))
        return sections
    }

    private func action(
        _ title: String,
        image: String,
        id: String,
        attributes: UIMenuElement.Attributes = [],
        state: UIMenuElement.State = .off,
        perform: @escaping () -> Void
    ) -> UIAction {
        let action = UIAction(title: title, image: UIImage(systemName: image),
                              attributes: attributes, state: state) { _ in
            perform()
        }
        action.accessibilityIdentifier = id
        return action
    }
}
#endif
