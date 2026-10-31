#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// New Agent Chat With…: the Mac's agents and their models, as the Mac's model
/// picker lists them (sections "Harness" and "Model"; an agent a phone can't start
/// is "Unavailable" with the Mac's reason). Start Chat opens the chat on the Mac.
struct AgentChooser: View {
    let load: @MainActor () async throws -> AgentCatalog
    let start: @MainActor (AgentChatStart) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var harnessID: String?
    @State private var modelID: String?

    enum Phase {
        case loading
        case loaded(AgentCatalog)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Agent Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start Chat") { startChat() }
                            .disabled(selection == nil)
                            .accessibilityIdentifier("agentChooser.start")
                    }
                }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading agents…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the agents", systemImage: "exclamationmark.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Check again") { Task { await reload() } }
            }
        case .loaded(let catalog):
            List {
                Section("Harness") {
                    ForEach(catalog.harnesses) { harness in
                        harnessRow(harness)
                    }
                }
                if let harness = selectedHarness(in: catalog), !harness.models.isEmpty {
                    Section("Model") {
                        modelRow(id: nil, name: harness.offeredDefaultModel.map { "Default (\(modelName($0, in: harness)))" } ?? "Default",
                                 reason: nil)
                        ForEach(harness.models.filter { $0.id != "default" }) { model in
                            modelRow(id: model.id, name: model.name, reason: model.unavailableReason)
                        }
                    }
                }
            }
        }
    }

    private func harnessRow(_ harness: AgentHarnessChoice) -> some View {
        Button {
            guard harness.canStart else { return }
            harnessID = harness.id
            modelID = nil
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.name).foregroundStyle(harness.canStart ? theme.colors.label.color : theme.colors.label2.color)
                    if let reason = harness.unavailableReason {
                        Text(reason).font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                    }
                }
                Spacer()
                Text(harness.canStart ? (harness.isDefault ? "Default" : "Ready") : "Unavailable")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2.color)
                if harness.id == harnessID {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!harness.canStart)
        .accessibilityIdentifier("agentChooser.harness.\(harness.id)")
    }

    private func modelRow(id: String?, name: String, reason: String?) -> some View {
        Button {
            guard reason == nil else { return }
            modelID = id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(reason == nil ? theme.colors.label.color : theme.colors.label2.color)
                    if let reason {
                        Text(reason).font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                    }
                }
                Spacer()
                if reason != nil {
                    Text("Unavailable").font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                }
                if id == modelID {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .accessibilityIdentifier("agentChooser.model.\(id ?? "default")")
    }

    private func modelName(_ id: String, in harness: AgentHarnessChoice) -> String {
        harness.models.first { $0.id == id }?.name ?? id
    }

    private func selectedHarness(in catalog: AgentCatalog) -> AgentHarnessChoice? {
        harnessID.flatMap(catalog.harness) ?? catalog.defaultChoice
    }

    private var selection: AgentChatStart? {
        guard case .loaded(let catalog) = phase, let harness = selectedHarness(in: catalog) else { return nil }
        return AgentChatStart(harness: harness.id, model: modelID)
    }

    private func startChat() {
        guard let selection else { return }
        dismiss()
        start(selection)
    }

    private func reload() async {
        phase = .loading
        do {
            let catalog = try await load()
            harnessID = catalog.defaultChoice?.id
            modelID = nil
            phase = .loaded(catalog)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
#endif
