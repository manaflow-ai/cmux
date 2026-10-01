import CmuxMobileRPC
import CmuxMobileShell
import SwiftUI

/// The iPhone/iPad counterpart of the Mac ACPmux surface. It uses the normal
/// authenticated mobile control stream, while keeping the transcript model
/// and UI independent of the legacy chat package.
struct AcpmuxMobileView: View {
    let client: MobileCoreRPCClient?
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [Session] = []
    @State private var selectedID: String?
    @State private var turns: [Turn] = []
    @State private var prompt = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private struct Session: Identifiable, Hashable {
        let id: String
        let name: String
        let status: String
    }

    private struct Turn: Identifiable, Hashable {
        let id = UUID()
        let role: String
        let text: String
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name).font(.headline)
                        Text(session.status).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
            }
            .navigationTitle("Agent sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createSession() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New agent session")
                }
            }
        } detail: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(turns) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.role)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(turn.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(turn.role == "You" ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .id(turn.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message agent", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    Button { send() } label: {
                        Image(systemName: isWorking ? "hourglass" : "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(isWorking || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedID == nil)
                }
                .padding()
            }
            .navigationTitle(sessions.first(where: { $0.id == selectedID })?.name ?? "Agent chat")
            .overlay {
                if client == nil {
                    ContentUnavailableView("Mac unavailable", systemImage: "bolt.horizontal.circle",
                                           description: Text("Connect to a Mac to use ACPmux."))
                }
            }
        }
        .alert("Agent chat", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task { await refresh() }
        .onChange(of: selectedID) { _, id in
            guard let id else { return }
            Task { await loadHistory(id: id) }
        }
    }

    private func refresh() async {
        guard let client else { return }
        do {
            let result = try await request(client, method: "mobile.acpmux.sessions")
            let rows = result["sessions"] as? [[String: Any]] ?? []
            sessions = rows.compactMap { row in
                guard let id = row["sessionId"] as? String else { return nil }
                return Session(id: id, name: row["name"] as? String ?? id,
                               status: row["status"] as? String ?? "unknown")
            }
            if selectedID == nil { selectedID = sessions.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createSession() {
        guard let client else { return }
        Task {
            do {
                let result = try await request(client, method: "mobile.acpmux.new", params: ["model": "claude"])
                guard let id = result["sessionId"] as? String else { throw MobileAcpmuxError.invalidResponse }
                selectedID = id
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadHistory(id: String) async {
        guard let client else { return }
        do {
            let result = try await request(client, method: "mobile.acpmux.history", params: ["sessionId": id])
            let rows = result["turns"] as? [[String: Any]] ?? []
            turns = rows.compactMap { row in
                guard let text = row["text"] as? String, !text.isEmpty else { return nil }
                return Turn(role: (row["role"] as? String ?? "event").capitalized, text: text)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func send() {
        guard let client, let selectedID else { return }
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        prompt = ""
        turns.append(Turn(role: "You", text: value))
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await request(client, method: "mobile.acpmux.send",
                                               params: ["sessionId": selectedID, "prompt": value])
                if let reply = result["reply"] as? String { turns.append(Turn(role: "Agent", text: reply)) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func request(_ client: MobileCoreRPCClient, method: String,
                         params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try MobileCoreRPCClient.requestData(method: method, params: params)
        let response = try await client.sendRequest(data)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["ok"] as? Bool == true,
              let result = object["result"] as? [String: Any] else {
            throw MobileAcpmuxError.invalidResponse
        }
        return result
    }
}

private enum MobileAcpmuxError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "The Mac returned an invalid ACPmux response." }
}

