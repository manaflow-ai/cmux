public import Foundation
public import Observation

/// Chats: the user's Claude Code and Codex chats, newest first, to pick up
/// in cmux. Each checked chat reopens as an agent tab in its project's
/// workspace, resumed rather than copied. None start checked: resuming one
/// starts its agent, which is the user's call. A keyboard cursor moves over
/// the rows; Space toggles the row under it.
@MainActor
@Observable
public final class ChatsStepModel {
    /// How many rows the step lists.
    static let listed = 60

    public private(set) var chats: [AgentChat] = []
    public private(set) var selected: Set<String> = []
    /// The row the keyboard is on.
    public private(set) var cursor = 0
    public private(set) var isScanning = false
    /// Whether a scan finished (an empty list then means nothing was found).
    public private(set) var scanned = false
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Chats already resumed, so Continue after Back resumes only new ones.
    @ObservationIgnored private var resumed: Set<String> = []

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// Starts the scan once; earlier steps start it so the list is ready.
    public func scan() {
        guard task == nil else { return }
        isScanning = true
        task = Task { [weak self, services] in
            let found = await services.scanAgentChats()
            guard let self, !Task.isCancelled else { return }
            chats = Array(found.prefix(Self.listed))
            isScanning = false
            scanned = true
        }
    }

    public func isSelected(_ chat: AgentChat) -> Bool { selected.contains(chat.id) }

    public func toggle(_ chat: AgentChat) {
        if selected.contains(chat.id) { selected.remove(chat.id) } else { selected.insert(chat.id) }
        if let index = chats.firstIndex(of: chat) { cursor = index }
    }

    /// Moves the keyboard cursor by `offset` rows, staying on the list.
    public func moveCursor(_ offset: Int) {
        guard !chats.isEmpty else { return }
        cursor = min(max(cursor + offset, 0), chats.count - 1)
    }

    /// Space: toggles the row under the cursor.
    public func toggleAtCursor() {
        guard chats.indices.contains(cursor) else { return }
        toggle(chats[cursor])
    }

    public var homeDirectory: URL { services.homeDirectory }

    /// The checked chats, in list order.
    public var chosen: [AgentChat] { chats.filter { selected.contains($0.id) } }

    /// Continue: resumes the checked chats, each once.
    func commit() {
        let chats = chosen.filter { !resumed.contains($0.id) }
        guard !chats.isEmpty else { return }
        resumed.formUnion(chats.map(\.id))
        services.resumeChats(chats)
    }

    func stop() {
        task?.cancel()
    }
}
