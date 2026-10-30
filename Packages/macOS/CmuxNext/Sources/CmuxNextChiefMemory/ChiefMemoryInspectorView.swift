public import CmuxNextDesign
public import SwiftUI

/// The built-in Memory Inspector: what the Chief reads (its view), each
/// line opened down to its messages, search, and the owner's edits,
/// deletes and undo. One per Chief, in a pane tab.
///
/// ```swift
/// ChiefMemoryInspectorView(model: ChiefMemoryInspectorModel(source: source, confirmDelete: confirm))
/// ```
public struct ChiefMemoryInspectorView: View {
    @Bindable var model: ChiefMemoryInspectorModel

    /// The view of `model`; it reads the memory when it appears.
    public init(model: ChiefMemoryInspectorModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                banner(error, symbol: "exclamationmark.triangle")
            } else if model.status?.editable == false {
                banner(ChiefMemoryStrings.readOnly, symbol: "lock")
            }
            HSplitView {
                list.frame(minWidth: 240, idealWidth: 340)
                detailColumn.frame(minWidth: 320)
            }
        }
        .task { await model.reload() }
    }

    /// The id of the delete dialog's Delete button.
    public static let deleteButton = "delete"

    /// The cmux dialog that confirms a delete (the app presents it over the tab).
    public static func deleteDialog(for target: ChiefMemoryTarget) -> CmuxDialogSpec {
        CmuxDialogSpec(title: ChiefMemoryStrings.deleteTitle, lines: [ChiefMemoryStrings.deleteMessage],
                       buttons: [.cancel(), CmuxDialogButton(id: deleteButton, title: ChiefMemoryStrings.deleteConfirm, role: .destructive)],
                       identifier: "chief-memory.delete")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let status = model.status {
                Text(String(format: ChiefMemoryStrings.counts, Int(status.messages), Int(status.nodesBuilt)))
                    .font(.callout).foregroundStyle(.secondary)
                if !status.stale.isEmpty {
                    Label(String(format: ChiefMemoryStrings.rebuilding, status.stale.count), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            TextField(ChiefMemoryStrings.search, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focusEffectDisabled()
                .frame(maxWidth: 260)
                .onSubmit { Task { await model.search() } }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.busy)
        }
        .padding(10)
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.secondary.opacity(0.1))
    }

    private var list: some View {
        let open = { (name: String) -> () -> Void in { _ = Task { await model.open(name) } } }
        let selected = model.trail.last
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty && !model.hits.isEmpty
        let lines = model.lines
        let hits = model.hits
        let stale = Set(model.status?.stale ?? [])
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(searching ? ChiefMemoryStrings.results : ChiefMemoryStrings.view)
                    .font(.headline).padding(.horizontal, 8).padding(.top, 8)
                if searching {
                    ForEach(hits) { hit in
                        ChiefMemoryLineRow(name: hit.name, detail: hit.type, text: hit.snippet, stale: stale.contains(hit.name),
                                           selected: selected == hit.name, open: open(hit.name))
                    }
                } else {
                    ForEach(lines.reversed()) { line in
                        ChiefMemoryLineRow(name: line.name, detail: "L\(line.level)", text: line.text ?? "…",
                                           stale: line.stale || stale.contains(line.name),
                                           selected: selected == line.name, open: open(line.name))
                    }
                }
            }
            .thinScrollers()
            .padding(6)
        }
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.trail.isEmpty {
                    HStack(spacing: 4) {
                        Button(ChiefMemoryStrings.back) { Task { await model.back() } }
                        Text(model.trail.joined(separator: " › "))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let node = model.detail {
                    section(ChiefMemoryStrings.summaryLine + " " + node.line.name,
                            target: .line(node.line.name), text: node.line.text ?? "…",
                            stale: model.isStale(node.line.name), editable: node.line.built)
                    if let message = node.message {
                        section(ChiefMemoryStrings.message + " \(message.id) · \(message.kind)",
                                target: .message(message.id), text: message.text, stale: false, editable: true)
                    }
                    if !node.children.isEmpty {
                        Text(ChiefMemoryStrings.covers).font(.headline)
                        let open = { (name: String) -> () -> Void in { _ = Task { await model.open(name) } } }
                        let stale = Set(model.status?.stale ?? [])
                        ForEach(node.children) { child in
                            ChiefMemoryLineRow(name: child.name, detail: "L\(child.level)", text: child.text ?? "…",
                                               stale: stale.contains(child.name), selected: false, open: open(child.name))
                        }
                    }
                } else {
                    Text(ChiefMemoryStrings.pickLine).foregroundStyle(.secondary)
                }
                Divider()
                changeList
            }
            .thinScrollers()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, target: ChiefMemoryTarget, text: String, stale: Bool, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if stale {
                    Text(ChiefMemoryStrings.stale).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if editable, model.status?.editable == true, model.editing != target {
                    Button(ChiefMemoryStrings.edit) { model.beginEdit(target) }
                    Button(ChiefMemoryStrings.delete, role: .destructive) { Task { await model.delete(target) } }
                }
            }
            if model.editing == target {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    CmuxDialogActionButton(ChiefMemoryStrings.cancel, hint: .escape) { model.cancelEdit() }
                    CmuxDialogActionButton(ChiefMemoryStrings.save, hint: .command("s")) { Task { await model.saveEdit() } }
                        .disabled(model.busy || model.draft == text)
                }
            } else {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var changeList: some View {
        let changes = model.changes
        let undo = { (id: UInt64) -> () -> Void in { _ = Task { await model.undo(id) } } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ChiefMemoryStrings.changes).font(.headline)
                Spacer()
                if changes.contains(where: { !$0.undone }), model.editing == nil {
                    Button(ChiefMemoryStrings.undo) { Task { await model.undoLast() } }
                        .keyboardShortcut("z", modifiers: .command)
                }
            }
            if changes.isEmpty {
                Text(ChiefMemoryStrings.noChanges).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(changes) { change in
                ChiefMemoryChangeRow(change: change, undo: undo(change.id))
            }
        }
    }
}
