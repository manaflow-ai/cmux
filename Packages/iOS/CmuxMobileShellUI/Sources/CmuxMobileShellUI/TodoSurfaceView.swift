import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Native iOS renderer for a Mac workspace todo surface.
struct TodoSurfaceView: View {
    let surface: MobileSurfacePreview
    @State private var model: TodoSurfaceModel
    @State private var pendingItemText = ""

    init(
        surface: MobileSurfacePreview,
        todo: MobileTodoSnapshot,
        mutate: @escaping @MainActor (MobileTodoMutation) async throws -> Void
    ) {
        self.surface = surface
        _model = State(initialValue: TodoSurfaceModel(snapshot: todo, mutate: mutate))
    }

    var body: some View {
        let snapshot = model.snapshot
        VStack(spacing: 0) {
            TodoSurfaceStatusHeader(
                title: surface.title,
                status: snapshot.status,
                statusHidden: snapshot.statusHidden,
                isEnabled: !model.isMutationPending,
                cycleStatus: { run(.cycleStatus) },
                setStatus: { run(.setStatus($0)) },
                openOnMac: { run(.openOnMac) }
            )
            Divider()

            List {
                if snapshot.items.isEmpty {
                    Text(L10n.string(
                        "mobile.todo.emptyChecklist",
                        defaultValue: "No checklist items yet."
                    ))
                    .foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                    TodoSurfaceRowView(
                        item: item,
                        displayIndex: index,
                        isEnabled: !model.isMutationPending,
                        actions: TodoSurfaceRowActions(
                            cycleState: { run(.setState(itemID: item.id, state: item.state.next)) },
                            edit: { run(.edit(itemID: item.id, text: $0)) },
                            move: { draggedID, targetIndex in
                                run(.move(itemID: draggedID, toIndex: targetIndex))
                            },
                            remove: { run(.remove(itemID: item.id)) }
                        )
                    )
                }
            }
            .listStyle(.plain)

            Divider()
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.string("mobile.todo.addPlaceholder", defaultValue: "New checklist item"),
                    text: $pendingItemText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .onSubmit(addPendingItem)
                Button(action: addPendingItem) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(!canAddPendingItem)
                .accessibilityLabel(L10n.string("mobile.todo.add", defaultValue: "Add checklist item"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .alert(
            L10n.string("mobile.todo.updateFailed.title", defaultValue: "Couldn’t Update Checklist"),
            isPresented: Binding(
                get: { model.showsMutationError },
                set: { if !$0 { model.dismissMutationError() } }
            )
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {
                model.dismissMutationError()
            }
        } message: {
            Text(L10n.string(
                "mobile.todo.updateFailed.message",
                defaultValue: "Your change was undone. Try again."
            ))
        }
        .onChange(of: surface.todo) { _, authoritative in
            if let authoritative { model.reconcile(authoritative) }
        }
    }

    private var canAddPendingItem: Bool {
        !model.isMutationPending
            && model.snapshot.items.count < MobileTodoSnapshot.maxItems
            && !pendingItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addPendingItem() {
        guard canAddPendingItem else { return }
        let text = pendingItemText
        pendingItemText = ""
        run(.add(text: text))
    }

    private func run(_ mutation: MobileTodoMutation) {
        Task { await model.perform(mutation) }
    }
}
