import CmuxBrowser
import SwiftUI

struct BrowserDesignModeEditor: View {
    let controller: BrowserDesignModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let snapshot = controller.snapshot,
               let selection = snapshot.selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        selectionHeader(selection)
                        layoutSection(snapshot)
                        spacingSection(snapshot)
                        typographySection(snapshot)
                        if selection.textEditable {
                            textSection(snapshot)
                        }
                        editsSection(snapshot)
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 520)
                .disabled(controller.handoffState == .preparing)
                footer
            } else {
                ContentUnavailableView(
                    String(localized: "browser.designMode.pick.title", defaultValue: "Pick an element"),
                    systemImage: "cursorarrow.rays",
                    description: Text(
                        String(
                            localized: "browser.designMode.pick.description",
                            defaultValue: "Hover the page to inspect its box model, then click an element to edit it."
                        )
                    )
                )
                .frame(width: 310, height: 190)
            }
        }
        .padding(12)
        .frame(width: 350)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintbrush.pointed.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "browser.designMode.title", defaultValue: "Design Mode"))
                    .cmuxFont(size: 13, weight: .semibold)
                Text(String(localized: "browser.designMode.live", defaultValue: "Edits are live and temporary"))
                    .cmuxFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { @MainActor in
                    _ = await controller.setEnabled(false, reason: "editor.done")
                }
            } label: {
                Text(String(localized: "common.done", defaultValue: "Done"))
            }
            .controlSize(.small)
        }
    }

    private func selectionHeader(_ selection: BrowserDesignModeSelection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.selector)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            Text(
                String(
                    format: String(
                        localized: "browser.designMode.selection.sizeFormat",
                        defaultValue: "%@ · %.0f × %.0f"
                    ),
                    selection.tagName,
                    selection.bounds.width,
                    selection.bounds.height
                )
            )
            .cmuxFont(size: 10)
            .foregroundStyle(.secondary)
        }
    }

    private func layoutSection(_ snapshot: BrowserDesignModeSnapshot) -> some View {
        editorSection(String(localized: "browser.designMode.section.layout", defaultValue: "Layout")) {
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.width", defaultValue: "Width"),
                currentValue: value(for: "width", in: snapshot)
            ) { value in
                applyStyle(property: "width", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.height", defaultValue: "Height"),
                currentValue: value(for: "height", in: snapshot)
            ) { value in
                applyStyle(property: "height", value: value)
            }
        }
    }

    private func spacingSection(_ snapshot: BrowserDesignModeSnapshot) -> some View {
        editorSection(String(localized: "browser.designMode.section.spacing", defaultValue: "Spacing")) {
            spacingGroup(
                title: String(localized: "browser.designMode.property.margin", defaultValue: "Margin"),
                prefix: "margin",
                snapshot: snapshot
            )
            spacingGroup(
                title: String(localized: "browser.designMode.property.padding", defaultValue: "Padding"),
                prefix: "padding",
                snapshot: snapshot
            )
        }
    }

    private func typographySection(_ snapshot: BrowserDesignModeSnapshot) -> some View {
        editorSection(String(localized: "browser.designMode.section.type", defaultValue: "Type & Color")) {
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.fontFamily", defaultValue: "Font family"),
                currentValue: value(for: "font-family", in: snapshot)
            ) { value in
                applyStyle(property: "font-family", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.fontSize", defaultValue: "Font size"),
                currentValue: value(for: "font-size", in: snapshot)
            ) { value in
                applyStyle(property: "font-size", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.lineHeight", defaultValue: "Line height"),
                currentValue: value(for: "line-height", in: snapshot)
            ) { value in
                applyStyle(property: "line-height", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.fontWeight", defaultValue: "Weight"),
                currentValue: value(for: "font-weight", in: snapshot)
            ) { value in
                applyStyle(property: "font-weight", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.color", defaultValue: "Text color"),
                currentValue: value(for: "color", in: snapshot)
            ) { value in
                applyStyle(property: "color", value: value)
            }
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.background", defaultValue: "Background"),
                currentValue: value(for: "background-color", in: snapshot)
            ) { value in
                applyStyle(property: "background-color", value: value)
            }
        }
    }

    private func textSection(_ snapshot: BrowserDesignModeSnapshot) -> some View {
        editorSection(String(localized: "browser.designMode.section.content", defaultValue: "Content")) {
            BrowserDesignModeValueField(
                title: String(localized: "browser.designMode.property.text", defaultValue: "Text"),
                currentValue: value(for: "text-content", in: snapshot)
            ) { value in
                Task { @MainActor in await controller.applyText(value) }
            }
        }
    }

    private func editsSection(_ snapshot: BrowserDesignModeSnapshot) -> some View {
        editorSection(
            String(
                format: String(
                    localized: "browser.designMode.section.editsFormat",
                    defaultValue: "Edits (%d)"
                ),
                snapshot.edits.count
            )
        ) {
            if snapshot.edits.isEmpty {
                Text(String(localized: "browser.designMode.edits.empty", defaultValue: "No changes yet."))
                    .cmuxFont(size: 10.5)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.edits) { edit in
                    BrowserDesignModeEditRow(edit: edit) {
                        Task { @MainActor in await controller.revert(editID: edit.id) }
                    }
                }
                Button(String(localized: "browser.designMode.revertAll", defaultValue: "Revert All")) {
                    Task { @MainActor in await controller.revertAll() }
                }
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = controller.errorMessage {
                Text(error)
                    .cmuxFont(size: 10)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { @MainActor in await controller.sendToAgent() }
            } label: {
                Label(sendButtonTitle, systemImage: sendButtonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canSendToAgent || controller.handoffState == .preparing)
        }
    }

    private var sendButtonTitle: String {
        switch controller.handoffState {
        case .preparing:
            String(localized: "browser.designMode.send.preparing", defaultValue: "Preparing…")
        case .sent:
            String(localized: "browser.designMode.send.sent", defaultValue: "Sent to Agent")
        case .idle, .failed:
            String(localized: "browser.designMode.send", defaultValue: "Send to Agent")
        }
    }

    private var sendButtonIcon: String {
        controller.handoffState == .sent ? "checkmark" : "paperplane"
    }

    private func value(for property: String, in snapshot: BrowserDesignModeSnapshot) -> String {
        if let edit = snapshot.edits.last(where: { $0.property == property }) { return edit.value }
        if property == "text-content" { return snapshot.selection?.textContent ?? "" }
        return snapshot.selection?.computedStyles[property] ?? ""
    }

    private func spacingGroup(
        title: String,
        prefix: String,
        snapshot: BrowserDesignModeSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .cmuxFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
            ForEach(["top", "right", "bottom", "left"], id: \.self) { edge in
                let property = "\(prefix)-\(edge)"
                BrowserDesignModeValueField(
                    title: edgeTitle(edge),
                    currentValue: value(for: property, in: snapshot)
                ) { value in
                    applyStyle(property: property, value: value)
                }
            }
        }
    }

    private func edgeTitle(_ edge: String) -> String {
        switch edge {
        case "top": String(localized: "browser.designMode.edge.top", defaultValue: "Top")
        case "right": String(localized: "browser.designMode.edge.right", defaultValue: "Right")
        case "bottom": String(localized: "browser.designMode.edge.bottom", defaultValue: "Bottom")
        default: String(localized: "browser.designMode.edge.left", defaultValue: "Left")
        }
    }

    private func applyStyle(property: String, value: String) {
        Task { @MainActor in
            await controller.applyStyle(property: property, value: value)
        }
    }

    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .cmuxFont(size: 9.5, weight: .semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
