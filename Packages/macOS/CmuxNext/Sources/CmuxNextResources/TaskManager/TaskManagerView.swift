public import AppKit
import CmuxNextDesign
public import SwiftUI

/// The Task Manager page: one row per cmux process with CPU and memory,
/// sortable by any column, and Kill Process on the selected row (the button
/// and the row menu). With `taskManagerMemorySaved`, the items Memory Saver
/// discarded follow the table, each with the memory it saved, and the footer
/// says what Memory Saver freed. The sort and the row to scroll back to are the tab's own
/// (``TaskManagerTableState``); the samples and the selection are the shared model's.
public struct TaskManagerView: View {
    @Bindable var model: TaskManagerModel
    @Bindable var table: TaskManagerTableState

    public init(model: TaskManagerModel, table: TaskManagerTableState) {
        self.model = model
        self.table = table
    }

    /// The page as an AppKit view: its `NSHostingView`, for the page tab's gate and for AppKit callers.
    public static func hostingView(model: TaskManagerModel, table: TaskManagerTableState) -> NSView {
        NSHostingView(rootView: TaskManagerView(model: model, table: table))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                rowsTable
                    .onAppear { scrollToTarget(proxy) }
                    .onChange(of: model.snapshot) { scrollToTarget(proxy) }
            }
            if !model.snapshot.discarded.isEmpty {
                Divider()
                TaskManagerDiscardedList(items: model.snapshot.discarded)
            }
            Divider()
            footer
        }
    }

    /// The saved top row of a view built again, once a sample lists it.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = table.scrollTarget, model.snapshot.row(target) != nil else { return }
        table.scrollTarget = nil
        proxy.scrollTo(target, anchor: .top)
    }

    private var rowsTable: some View {
        Table(table.rows(of: model.snapshot), selection: $model.selection, sortOrder: $table.sortOrder) {
            TableColumn(TaskManagerStrings.columnTask, value: \.task)
            TableColumn(TaskManagerStrings.columnProcess, value: \.name)
            TableColumn(TaskManagerStrings.columnPID, value: \.pid) { row in
                Text(verbatim: row.id.host == ProcessKey.localHost ? String(row.pid) : row.id.description)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn(TaskManagerStrings.columnCPU, value: \.cpuSortValue) { row in
                Text(verbatim: row.cpu.map { ResourceFormat.cpu($0) } ?? Strings.pending).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn(TaskManagerStrings.columnMemory, value: \.memoryBytes) { row in
                Text(verbatim: ResourceFormat.memory(row.memoryBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: ProcessKey.self) { keys in
            if keys.count == 1, let key = keys.first {
                Button(TaskManagerStrings.killMenu) { model.kill(key) }
            }
        }
        .overlay {
            if model.snapshot.rows.isEmpty { Text(TaskManagerStrings.empty).foregroundStyle(.secondary) }
        }
    }

    private var footer: some View {
        HStack {
            Text(TaskManagerStrings.total(ResourceFormat.line(model.snapshot.total)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if model.snapshot.freedBytes > 0 {
                Text(TaskManagerStrings.memorySaverFreed(ResourceFormat.memory(model.snapshot.freedBytes)))
                    .font(Font(Typography.body))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(TaskManagerStrings.killButton) {
                if let row = model.selectedRow { model.kill(row.id) }
            }
            .disabled(model.selectedRow == nil)
        }
        .padding(8)
    }
}

/// The items Memory Saver discarded: each one's title and "Discarded, saved about N MB". They have
/// no process, so they are not rows of the process table and Kill Process does not apply to them.
/// The list grows with its items up to `maxHeight`, then scrolls.
private struct TaskManagerDiscardedList: View {
    let items: [TaskManagerDiscardedItem]
    private static let maxHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TaskManagerStrings.discardedHeader)
                .font(Font(Typography.bodyEmphasized))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Text(verbatim: item.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(TaskManagerStrings.discarded(saved: item.savedBytes.map { ResourceFormat.memory($0) }))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(Font(Typography.body))
                    }
                }
            }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }
}
