import CmuxNextBrowser
import CmuxNextWakeups
import Foundation

/// JavaScript dialogs of driven tabs as driver events. WebKitTab turns
/// alert, confirm and prompt into `pendingPrompts`; the broker watches that
/// list with one automation-class ``ServiceObservation`` per tab (no polling;
/// the person's input goes first), sends `dialog.opened` for each new
/// dialog, and answers it on `dialog.respond`. A dialog stays open until it
/// is answered, as #15570's driver keeps it (the snapshot shows it).
@MainActor
final class DialogBroker {
    private var dialogs: [String: BrowserPrompt] = [:]
    private var seen: Set<ObjectIdentifier> = []
    /// Each watched tab's prompt observation; removing one stops it.
    private var watched: [BrowserTabID: ServiceObservation<[BrowserPrompt]>] = [:]
    private let work: MainWorkScheduler
    private let emit: (String, [String: DriverJSON]) -> Void

    init(work: MainWorkScheduler, emit: @escaping (String, [String: DriverJSON]) -> Void) {
        self.work = work
        self.emit = emit
    }

    /// Starts watching a tab's prompts; idempotent.
    func watch(_ tab: WebKitTab) {
        guard watched[tab.id] == nil else { return }
        watched[tab.id] = ServiceObservation(.automation, owner: "browser-automation.dialogs", on: work) { [weak tab] in
            tab?.pendingPrompts ?? []
        } apply: { [weak self, weak tab] prompts in
            guard let self, let tab else { return }
            self.opened(prompts, in: tab)
        }
    }

    func stopWatching(_ id: BrowserTabID) {
        watched.removeValue(forKey: id)?.cancel()
    }

    /// Sends `dialog.opened` for each prompt not seen before.
    private func opened(_ prompts: [BrowserPrompt], in tab: WebKitTab) {
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
        // Permission and HTTP credential prompts stay the person's: an agent
        // never answers them (credentials, plans/cmux-next/passwords.md).
        // Nor is another app opened for an agent, nor a password saved, nor
        // an email's verification code read or filled, nor a page's
        // "Leave site?" answered (unsaved work is the person's).
        case .permission, .credentials, .openExternalApp, .savePassword, .verificationOffer, .beforeUnload: nil
        }
    }
}
