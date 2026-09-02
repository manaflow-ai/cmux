import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Native iOS renderer for a Mac workspace todo surface.
struct TodoSurfaceView: View {
    let surface: MobileSurfacePreview
    /// False while the owning Mac can't take todo mutations (reconnecting, or
    /// a Mac without `todo.v1`): the last synced checklist stays readable and
    /// every mutating control is disabled, mirroring the terminal's blocked
    /// input during recovery.
    let allowsMutations: Bool
    @State private var model: TodoSurfaceModel
    @State private var pendingItemText = ""
    @FocusState private var composerFocused: Bool

    init(
        surface: MobileSurfacePreview,
        todo: MobileTodoSnapshot,
        allowsMutations: Bool,
        mutate: @escaping @MainActor (MobileTodoMutation) async throws -> Void
    ) {
        self.surface = surface
        self.allowsMutations = allowsMutations
        _model = State(initialValue: TodoSurfaceModel(snapshot: todo, mutate: mutate))
    }

    var body: some View {
        let snapshot = model.snapshot
        VStack(spacing: 0) {
            // The navigation bar already names the surface; the pane keeps
            // only the functional chrome (status control + progress).
            HStack(spacing: 12) {
                if let subtitle = progressSubtitle(snapshot) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TodoStatusMenu(
                    status: snapshot.status,
                    statusHidden: snapshot.statusHidden,
                    isEnabled: allowsMutations && !model.isMutationPending,
                    setStatus: { run(.setStatus($0)) }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            if let progress = completionProgress(snapshot) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progress >= 1 ? MobileTodoStatus.done.tint : nil)
                    .animation(.snappy, value: progress)
            }

            if snapshot.items.isEmpty {
                MacSurfaceMessageView(
                    systemImage: "checklist",
                    title: L10n.string("mobile.todo.empty.title", defaultValue: "No items yet"),
                    message: L10n.string(
                        "mobile.todo.empty.message",
                        defaultValue: "Anything you add here stays in sync with your Mac."
                    )
                )
            } else {
                List {
                    ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                        TodoSurfaceRowView(
                            item: item,
                            displayIndex: index,
                            isEnabled: allowsMutations && !model.isMutationPending,
                            actions: TodoSurfaceRowActions(
                                cycleState: { run(.setState(itemID: item.id, state: item.state.next)) },
                                edit: { run(.edit(itemID: item.id, text: $0)) },
                                move: { draggedID, targetIndex in
                                    run(.move(itemID: draggedID, toIndex: targetIndex))
                                },
                                remove: { run(.remove(itemID: item.id)) }
                            )
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .animation(.snappy, value: snapshot.items)
            }

            composer
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
        .onChange(of: model.showsMutationError) { _, showsError in
            guard showsError else { return }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        }
        .onChange(of: surface.todo) { _, authoritative in
            if let authoritative { model.reconcile(authoritative) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                L10n.string("mobile.todo.addPlaceholder", defaultValue: "New checklist item"),
                text: $pendingItemText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .focused($composerFocused)
            .onSubmit(addPendingItem)
            .submitLabel(.done)

            Button(action: addPendingItem) {
                Image(systemName: "arrow.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(canAddPendingItem ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(canAddPendingItem ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canAddPendingItem)
            .animation(.snappy, value: canAddPendingItem)
            .accessibilityLabel(L10n.string("mobile.todo.add", defaultValue: "Add checklist item"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .mobileGlassField(cornerRadius: 22)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func progressSubtitle(_ snapshot: MobileTodoSnapshot) -> String? {
        guard !snapshot.items.isEmpty else { return nil }
        let done = snapshot.items.count(where: { $0.state == .completed })
        let format = L10n.string(
            "mobile.todo.progressFormat",
            defaultValue: "%1$d of %2$d done"
        )
        return String.localizedStringWithFormat(format, done, snapshot.items.count)
    }

    private func completionProgress(_ snapshot: MobileTodoSnapshot) -> Double? {
        guard !snapshot.items.isEmpty else { return nil }
        let done = snapshot.items.count(where: { $0.state == .completed })
        return Double(done) / Double(snapshot.items.count)
    }

    private var canAddPendingItem: Bool {
        allowsMutations
            && !model.isMutationPending
            && model.snapshot.items.count < MobileTodoSnapshot.maxItems
            && !pendingItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addPendingItem() {
        guard canAddPendingItem else { return }
        let text = pendingItemText
        pendingItemText = ""
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        run(.add(text: text))
    }

    private func run(_ mutation: MobileTodoMutation) {
        guard allowsMutations else { return }
        Task { await model.perform(mutation) }
    }
}
