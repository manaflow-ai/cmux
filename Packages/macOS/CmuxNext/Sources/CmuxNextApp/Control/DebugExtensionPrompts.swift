import CmuxNextBrowser
import CmuxNextSettings

#if DEBUG
/// `debug.extensions.prompt`: extension install and permission prompts on
/// screen (Web Store "Add to Chrome", `chrome.permissions.request`).
/// `{}` lists them; `{id, answer: "accept" | "cancel"}` answers one as its
/// sheet's buttons do.
@MainActor
enum DebugExtensionPrompts {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let engine = services.cache.cef
        if let id = params["id"]?.intValue, let answer = params["answer"]?.stringValue {
            let value: ExtensionInstallPrompt.Answer = answer == "accept" ? .accept : .cancel
            return .object(["ok": .bool(engine.answerExtensionPrompt(Int32(id), value))])
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
