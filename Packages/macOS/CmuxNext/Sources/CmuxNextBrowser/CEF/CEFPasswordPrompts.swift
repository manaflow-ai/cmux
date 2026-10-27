import CmuxNextCompat
import Foundation

/// Chromium's password save and update prompts (fork API 20, passwords.md
/// 1.1), asked in the tab's prompt bar instead of Chromium's bubble, which
/// would anchor to the toolbar cmux hides. Only origins and usernames come
/// here; the password stays inside Chromium from the form to the store.
/// Chromium never prompts in an agent-driven tab (password filling off), an
/// incognito profile or for a never-save site, and agents cannot answer the
/// prompt (`DialogBroker`).
struct CEFPasswordPrompts {
    /// `cmux_password_prompt_action_t`.
    enum Action: Int32 {
        case save = 0, update = 1, never = 2, dismiss = 3
    }

    /// Prompts on screen by Chromium prompt id, so a "gone" prompt leaves the bar.
    private static var open: [Int32: BrowserPrompt] = [:]

    let tab: CEFTab

    func arrived(promptID: Int32, json: String) {
        guard let object = try? JSONSerialization.blockingJSONObject(with: Data(json.utf8)) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        let runtime = tab.runtime
        guard kind == "save" || kind == "update" else {
            // "gone": the tab navigated or closed; Chromium already dropped it.
            Self.open.removeValue(forKey: promptID)?.respond(.cancel)
            return
        }
        // Offer to Save Passwords off: Chromium's question goes unasked.
        guard CEFPasswordPolicy.offerToSave else {
            _ = runtime.shim?.passwordPromptAnswer(promptID, Action.dismiss.rawValue, nil)
            return
        }
        let update = kind == "update"
        // Chromium skips a tab with filling off; this holds even on a fork that does not.
        guard !tab.isAgentDriven else {
            _ = runtime.shim?.passwordPromptAnswer(promptID, Action.dismiss.rawValue, nil)
            return
        }
        let origin = object["origin"] as? String ?? ""
        let username = object["username"] as? String ?? ""
        tab.enqueuePrompt(.savePassword(username: username, update: update), origin: origin) { response in
            Self.open.removeValue(forKey: promptID)
            let action: Action = switch response {
            case .accept: update ? .update : .save
            case .deny: update ? .dismiss : .never
            default: .dismiss
            }
            _ = runtime.shim?.passwordPromptAnswer(promptID, action.rawValue, nil)
        }
        if let prompt = tab.pendingPrompts.last, case .savePassword = prompt.kind { Self.open[promptID] = prompt }
    }
}
