import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class TemplateManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TemplateManagerWindowController()

    private let viewModel = TemplateManagerViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "templateManager.windowTitle",
            defaultValue: "Template Manager"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 400)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.templateManager")
        window.setFrameAutosaveName("cmux.templateManager")
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: TemplateManagerView(viewModel: viewModel))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        viewModel.reload()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if viewModel.isDirty {
            promptUnsavedChanges { [weak self] in
                self?.window?.close()
            }
            return false
        }
        return true
    }

    private func promptUnsavedChanges(onDiscard: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "templateManager.unsavedChanges.title",
            defaultValue: "Unsaved Changes"
        )
        alert.informativeText = String(
            localized: "templateManager.unsavedChanges.message",
            defaultValue: "Do you want to save your changes before closing?"
        )
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.viewModel.save()
                onDiscard()
            case .alertSecondButtonReturn:
                self?.viewModel.revert()
                onDiscard()
            default:
                break
            }
        }
    }
}

// MARK: - SwiftUI View

struct TemplateManagerView: View {
    @ObservedObject var viewModel: TemplateManagerViewModel

    @State private var pendingSelection: String?

    var body: some View {
        HSplitView {
            templateList
                .frame(minWidth: 160, maxWidth: 220)

            editorPane
                .frame(minWidth: 300)

            TemplateManagerHelpSidebar()
                .frame(minWidth: 200, maxWidth: 260)
        }
    }

    // MARK: - Template List

    private var templateList: some View {
        VStack(spacing: 0) {
            List(viewModel.templateNames, id: \.self, selection: $pendingSelection) { name in
                Text(name)
            }
            .onChange(of: pendingSelection) { newValue in
                guard let newValue, newValue != viewModel.selectedName else { return }
                if viewModel.isDirty {
                    promptDirtySwitch(to: newValue)
                } else {
                    viewModel.selectTemplate(named: newValue)
                }
            }

            HStack(spacing: 4) {
                Button(action: viewModel.addTemplate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button(action: viewModel.duplicateSelected) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selectedName == nil)

                Button(action: confirmDelete) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selectedName == nil)

                Spacer()
            }
            .padding(6)
        }
    }

    // MARK: - Editor

    private var editorPane: some View {
        VStack(spacing: 0) {
            if viewModel.selectedName != nil {
                MonospaceTextEditor(
                    text: viewModel.editorText,
                    onChange: viewModel.textDidChange
                )

                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "common.revert", defaultValue: "Revert")) {
                        viewModel.revert()
                    }
                    .disabled(!viewModel.isDirty)

                    Button(String(localized: "common.save", defaultValue: "Save")) {
                        viewModel.save()
                    }
                    .disabled(!viewModel.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(8)
            } else {
                Text(String(
                    localized: "templateManager.noSelection",
                    defaultValue: "Select a template to edit"
                ))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func confirmDelete() {
        guard let name = viewModel.selectedName else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "templateManager.deleteConfirm.title",
                defaultValue: "Delete Template?"
            )
            alert.informativeText = String(
                localized: "templateManager.deleteConfirm.message",
                defaultValue: "Are you sure you want to delete \"\(name)\"? This cannot be undone."
            )
            alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
            alert.buttons.first?.hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                self.viewModel.deleteSelected()
                self.pendingSelection = self.viewModel.selectedName
            }
        }
    }

    private func promptDirtySwitch(to newName: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "templateManager.unsavedChanges.title",
            defaultValue: "Unsaved Changes"
        )
        alert.informativeText = String(
            localized: "templateManager.unsavedChanges.switchMessage",
            defaultValue: "Save changes before switching?"
        )
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            viewModel.save()
            viewModel.selectTemplate(named: newName)
        case .alertSecondButtonReturn:
            viewModel.selectTemplate(named: newName)
        default:
            pendingSelection = viewModel.selectedName
        }
    }
}
