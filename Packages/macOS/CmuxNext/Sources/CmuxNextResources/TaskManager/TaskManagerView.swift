public import SwiftUI

/// The Task Manager page: one row per cmux process with CPU and memory,
/// sortable by any column, and Kill Process on the selected row (the button
/// and the row menu).
public struct TaskManagerView: View {
    @Bindable var model: TaskManagerModel
    @State private var order: [KeyPathComparator<TaskManagerRow>] = []

    public init(model: TaskManagerModel) {
        self.model = model
    }

    private var rows: [TaskManagerRow] {
        order.isEmpty ? model.snapshot.rows : model.snapshot.rows.sorted(using: order)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $model.selection, sortOrder: $order) {
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
            Divider()
            HStack {
                Text(TaskManagerStrings.total(ResourceFormat.line(model.snapshot.total)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(TaskManagerStrings.killButton) {
                    if let row = model.selectedRow { model.kill(row.id) }
                }
                .disabled(model.selectedRow == nil)
            }
            .padding(8)
        }
    }
}
