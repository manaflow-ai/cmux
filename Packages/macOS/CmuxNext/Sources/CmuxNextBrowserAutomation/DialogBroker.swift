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
        // Swift drops the held dialog before reading `accept`, as before: it is gone after any call that got past the id.
        let id = params.has("dialogId") ? (try? params.string("dialogId")) : nil
        let prompt = id.flatMap { dialogs.removeValue(forKey: $0) }
        var request: [String: Any] = ["params": BrowserRulesFFI.foundation(params.json)]
        if let prompt {
            request["held"] = Self.wire(prompt.kind)
            request["resolved"] = prompt.isResolved
        }
        guard case .object(let reply)? = BrowserRulesFFI.call("dialog_respond", request) else {
            throw DriverError(.unsupported, "dialog.respond: the app's rules library did not answer")
        }
        if case .object(let failure)? = reply["error"] {
            let code = failure["code"]?.stringValue.flatMap(DriverError.Code.init(rawValue:)) ?? .invalid
            throw DriverError(code, failure["message"]?.stringValue ?? "dialog.respond failed")
        }
        guard let prompt, case .object(let answer)? = reply["answer"] else { return .null }
        switch answer["kind"]?.stringValue {
        case "text": prompt.respond(.text(answer["text"]?.stringValue ?? ""))
        case "accept": prompt.respond(.accept)
        default: prompt.respond(.cancel)
        }
        return .null
    }

    /// What `dialog.opened` says of a prompt, or nil for one that stays the
    /// person's (Rust: op `browser_rules_automation_dialog_describe`).
    static func describe(_ kind: BrowserPromptKind) -> (String, String, String)? {
        guard case .object(let reply)? = BrowserRulesFFI.call("dialog_describe", ["prompt": wire(kind)]),
              let type = reply["type"]?.stringValue, let message = reply["message"]?.stringValue else { return nil }
        return (type, message, reply["defaultValue"]?.stringValue ?? "")
    }

    /// A prompt kind as the rules read it. Permission and HTTP credential
    /// prompts, another app, a saved password, an email's verification code
    /// and a page's "Leave site?" stay the person's: an agent never answers
    /// them (plans/cmux-next/passwords.md), so they cross with no fields.
    static func wire(_ kind: BrowserPromptKind) -> [String: Any] {
        switch kind {
        case .alert(let message): ["kind": "alert", "message": message]
        case .confirm(let message): ["kind": "confirm", "message": message]
        case .textInput(let message, let defaultText):
            defaultText.map { ["kind": "textInput", "message": message, "defaultText": $0] } ?? ["kind": "textInput", "message": message]
        case .permission, .credentials, .openExternalApp, .noAppForScheme, .savePassword, .verificationOffer, .beforeUnload: ["kind": "personOnly"]
        }
    }
}
