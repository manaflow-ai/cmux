import CmuxNextBrowser
import Foundation
import Observation

/// JavaScript dialogs of driven tabs as driver events. WebKitTab turns
/// alert, confirm and prompt into `pendingPrompts`; the broker watches that
/// list with Observation (no polling), sends `dialog.opened` for each new
/// dialog, and answers it on `dialog.respond`. A dialog stays open until it
/// is answered, as #15570's driver keeps it (the snapshot shows it).
@MainActor
final class DialogBroker {
    private var dialogs: [String: BrowserPrompt] = [:]
    private var seen: Set<ObjectIdentifier> = []
    private var watched: Set<BrowserTabID> = []
    private let emit: (String, [String: DriverJSON]) -> Void

    init(emit: @escaping (String, [String: DriverJSON]) -> Void) {
        self.emit = emit
    }

    /// Starts watching a tab's prompts; idempotent.
    func watch(_ tab: WebKitTab) {
        guard watched.insert(tab.id).inserted else { return }
        observe(tab)
    }

    func stopWatching(_ id: BrowserTabID) {
        watched.remove(id)
    }

    private func observe(_ tab: WebKitTab) {
        guard watched.contains(tab.id) else { return }
        let prompts = withObservationTracking {
            tab.pendingPrompts
        } onChange: { [weak self, weak tab] in
            Task { @MainActor in
                guard let self, let tab else { return }
                self.observe(tab)
            }
        }
        for prompt in prompts where seen.insert(ObjectIdentifier(prompt)).inserted {
            guard let (type, message, defaultValue) = Self.describe(prompt.kind) else { continue }
            let id = prompt.id.uuidString
            dialogs[id] = prompt
            emit("dialog.opened", [
                "targetId": .string(tab.id.rawValue), "dialogId": .string(id), "type": .string(type),
                "message": .string(message), "defaultValue": .string(defaultValue),
            ])
        }
    }

    func respond(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let id = try params.string("dialogId")
        guard let prompt = dialogs.removeValue(forKey: id), !prompt.isResolved else {
            throw DriverError(.notFound, "Dialog \(id) is gone")
        }
        let accept = try params.bool("accept")
        switch prompt.kind {
        case .textInput(_, let defaultText) where accept:
            prompt.respond(.text(try params.optionalString("promptText") ?? defaultText ?? ""))
        default:
            prompt.respond(accept ? .accept : .cancel)
        }
        return .null
    }

    private static func describe(_ kind: BrowserPromptKind) -> (String, String, String)? {
        switch kind {
        case .alert(let message): ("alert", message, "")
        case .confirm(let message): ("confirm", message, "")
        case .textInput(let message, let defaultText): ("prompt", message, defaultText ?? "")
        case .permission: nil
        }
    }
}
