// Phone tabs (plans/cmux-next/phone.md): a simulator or a real iPhone in a
// pane tab, with screenshots, recordings and one-click feedback to Chief.
// Titles live in PhoneActions.xcstrings. Every action is a `cmux phone ...`
// verb and an MCP tool, so agents drive the phone the way a person does.
// `device` takes a phone id (`sim:<udid>`, `dev:<udid>`); without it the
// recorded phone, else the first booted simulator.

nonisolated enum PhoneActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let device = ActionArgument(name: "device", title: t("argument.phone.device", "Phone"), kind: .string, isRequired: false)
        let notes = ActionArgument(name: "notes", title: t("argument.phone.notes", "Notes"), kind: .string, isRequired: false)
        let path = ActionArgument(name: "path", title: t("argument.phone.path", "File"), kind: .string, isRequired: false)
        func phone(_ id: ActionID, _ key: StaticString, _ english: String.LocalizationValue, symbol: String,
                   keywords: [String], cliName: String, arguments: [ActionArgument]) -> ActionDescriptor {
            ActionDescriptor(
                id: id, title: t(key, english), keywords: ["phone", "iphone", "simulator", "ios"] + keywords,
                category: .other, symbol: symbol, surfaces: [.palette, .keyboard], arguments: arguments,
                cliName: cliName,
                // Not tied to a right-clicked object: each acts on a phone, named by `device`.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject))
        }
        return [
            phone("phone.show", "action.phone.show", "Open Phone", symbol: "iphone",
                  keywords: ["open", "device", "mirror", "screen"], cliName: "phone open", arguments: [device]),
            phone("phone.boot", "action.phone.boot", "Boot Phone", symbol: "power",
                  keywords: ["boot", "start"], cliName: "phone boot", arguments: [device]),
            phone("phone.screenshot", "action.phone.screenshot", "Take Phone Screenshot", symbol: "camera",
                  keywords: ["screenshot", "capture", "png"], cliName: "phone screenshot", arguments: [device, path]),
            phone("phone.recordStart", "action.phone.recordStart", "Record Phone", symbol: "record.circle",
                  keywords: ["record", "video", "feedback", "bug"], cliName: "phone record start", arguments: [device]),
            phone("phone.recordStop", "action.phone.recordStop", "Stop Phone Recording", symbol: "stop.circle",
                  keywords: ["record", "stop", "video"], cliName: "phone record stop", arguments: [notes]),
            phone("phone.sendFeedback", "action.phone.sendFeedback", "Send Phone Recording to Chief", symbol: "paperplane",
                  keywords: ["feedback", "bug", "report", "chief", "send", "clip"], cliName: "phone feedback", arguments: [notes]),
            phone("phone.openURL", "action.phone.openURL", "Open URL on Phone", symbol: "link",
                  keywords: ["url", "link", "deep link", "open"], cliName: "phone open-url",
                  arguments: [ActionArgument(name: "url", title: t("argument.phone.url", "URL"), kind: .string), device]),
            phone("phone.paste", "action.phone.paste", "Copy Text to Phone", symbol: "doc.on.clipboard",
                  keywords: ["paste", "clipboard", "text", "copy"], cliName: "phone paste",
                  arguments: [ActionArgument(name: "text", title: t("argument.phone.text", "Text"), kind: .string), device]),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "PhoneActions", bundle: .module)
    }
}
