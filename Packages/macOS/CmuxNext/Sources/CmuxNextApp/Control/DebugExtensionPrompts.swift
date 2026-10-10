import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSettings

#if DEBUG
/// `debug.extensions.prompt`: extension install and permission prompts on
/// screen (Web Store "Add to Chrome", `chrome.permissions.request`).
/// `{}` lists them; `{id, answer: "cancel"}` answers one as its Cancel does; an
/// "accept" answer is the user's (cx-zk9t): use the DEBUG fixture `fixture_answer`.
@MainActor
enum DebugExtensionPrompts {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let engine = services.cache.cef
        // DEV-only test fixture (cx-zk9t; this file is DEBUG-only): `{id, fixture_answer:
        // "accept" | "cancel"}` answers without the dialog, for e2e scripts that must accept.
        if let id = params["id"]?.intValue, let answer = params["fixture_answer"]?.stringValue {
            return .object(["ok": .bool(engine.fixtureAnswerExtensionPrompt(Int32(id), answer == "accept" ? .accept : .cancel))])
        }
        if let id = params["id"]?.intValue, let answer = params["answer"]?.stringValue {
            // The prompt's sheet is a trust dialog: through the center's automation door
            // (cx-zk9t) only cancel passes; accept is the user's.
            let center = CmuxDialogCenter.shared
            guard let dialog = center.records.first(where: { $0.spec.identifier == "browser.extensionPrompt.\(id)" }) else {
                return .object(["ok": false])
            }
            do throws(CmuxDialogAutomationRefusal) {
                return .object(["ok": .bool(try center.automationPress(dialog.id, button: answer == "accept" ? "accept" : "cancel"))])
            } catch {
                return .object(["ok": false, "error": .string(error.message),
                                "refused": .object(["dialog": .number(Double(error.dialog)), "confirm_kind": .string(error.kind.rawValue)])])
            }
        }
        return .object(["prompts": .array(engine.extensionPrompts.map { prompt in
            .object([
                "id": .number(Double(prompt.id)), "kind": .string(prompt.kind.rawValue),
                "extension_id": .string(prompt.extensionID), "name": .string(prompt.name),
                "permissions": .array(prompt.permissions.map { .string($0.message) }),
                "browser": .number(Double(prompt.browser)),
            ])
        })])
    }
}
#endif
