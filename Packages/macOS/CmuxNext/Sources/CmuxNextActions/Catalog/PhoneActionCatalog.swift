// Phone tabs (plans/cmux-next/phone.md, simulators-DESIGN.md): an iOS
// simulator, an Android emulator or a real phone in a pane tab, with live
// input, screenshots, recordings, logs and one-click feedback to Chief.
// Titles live in PhoneActions.xcstrings. Every action is a `cmux phone ...`
// verb and an MCP tool, so agents drive the phone the way a person does.
// `device` takes a phone id (`sim:<udid>`, `dev:<udid>`, `avd:<name>`,
// `adb:<serial>`) or a name; without it the recorded phone, else the first
// booted simulator. Points are the phone's own (iOS points, Android dp), the
// same space `phone ui` reports frames in.

nonisolated enum PhoneActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let device = ActionArgument(name: "device", title: t("argument.phone.device", "Phone"), kind: .string, isRequired: false)
        let notes = ActionArgument(name: "notes", title: t("argument.phone.notes", "Notes"), kind: .string, isRequired: false)
        let path = ActionArgument(name: "path", title: t("argument.phone.path", "File"), kind: .string, isRequired: false)
        func phone(_ id: ActionID, _ key: StaticString, _ english: String.LocalizationValue, symbol: String,
                   keywords: [String], cliName: String, arguments: [ActionArgument]) -> ActionDescriptor {
            ActionDescriptor(
                id: id, title: t(key, english), keywords: ["phone", "iphone", "simulator", "ios"] + keywords,
                category: .browser, symbol: symbol, surfaces: [.palette, .keyboard], arguments: arguments,
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
                  keywords: ["record", "video", "feedback", "bug"], cliName: "phone record", arguments: [device]),
            phone("phone.recordStop", "action.phone.recordStop", "Stop Phone Recording", symbol: "stop.circle",
                  keywords: ["record", "stop", "video"], cliName: "phone stop", arguments: [notes]),
            phone("phone.sendFeedback", "action.phone.sendFeedback", "Send Phone Recording to Chief", symbol: "paperplane",
                  keywords: ["feedback", "bug", "report", "chief", "send", "clip"], cliName: "phone feedback", arguments: [notes]),
            phone("phone.openURL", "action.phone.openURL", "Open URL on Phone…", symbol: "link",
                  keywords: ["url", "link", "deep link", "open"], cliName: "phone open-url",
                  arguments: [ActionArgument(name: "url", title: t("argument.phone.url", "URL"), kind: .string), device]),
            phone("phone.paste", "action.phone.paste", "Copy Text to Phone…", symbol: "doc.on.clipboard",
                  keywords: ["paste", "clipboard", "text", "copy"], cliName: "phone paste",
                  arguments: [ActionArgument(name: "text", title: t("argument.phone.text", "Text"), kind: .string), device]),
            phone("phone.list", "action.phone.list", "List Phones", symbol: "list.bullet",
                  keywords: ["list", "devices", "android", "emulator"], cliName: "phone list", arguments: []),
            phone("phone.shutdown", "action.phone.shutdown", "Shut Down Phone", symbol: "power",
                  keywords: ["shutdown", "stop", "off"], cliName: "phone shutdown", arguments: [device]),
            phone("phone.tap", "action.phone.tap", "Tap Phone Screen…", symbol: "hand.tap",
                  keywords: ["tap", "touch", "click"], cliName: "phone tap",
                  arguments: [number("x", "argument.phone.x", "X"), number("y", "argument.phone.y", "Y"), device]),
            phone("phone.swipe", "action.phone.swipe", "Swipe on Phone…", symbol: "hand.draw",
                  keywords: ["swipe", "scroll", "drag"], cliName: "phone swipe",
                  arguments: [number("fromX", "argument.phone.fromX", "From X"), number("fromY", "argument.phone.fromY", "From Y"),
                              number("toX", "argument.phone.toX", "To X"), number("toY", "argument.phone.toY", "To Y"),
                              ActionArgument(name: "seconds", title: t("argument.phone.seconds", "Seconds"), kind: .string, isRequired: false),
                              device]),
            phone("phone.type", "action.phone.type", "Type on Phone…", symbol: "keyboard",
                  keywords: ["type", "text", "keyboard"], cliName: "phone type",
                  arguments: [ActionArgument(name: "text", title: t("argument.phone.text", "Text"), kind: .string), device]),
            phone("phone.button", "action.phone.button", "Press Phone Button…", symbol: "button.programmable",
                  keywords: ["button", "home", "lock", "volume", "back"], cliName: "phone button",
                  arguments: [ActionArgument(name: "button", title: t("argument.phone.button", "Button"), kind: .enumeration([
                      ActionEnumCase(value: "home", title: t("argument.phone.button.home", "Home")),
                      ActionEnumCase(value: "lock", title: t("argument.phone.button.lock", "Lock")),
                      ActionEnumCase(value: "volume-up", title: t("argument.phone.button.volumeUp", "Volume Up")),
                      ActionEnumCase(value: "volume-down", title: t("argument.phone.button.volumeDown", "Volume Down")),
                      ActionEnumCase(value: "siri", title: t("argument.phone.button.siri", "Siri or Assistant")),
                      ActionEnumCase(value: "back", title: t("argument.phone.button.back", "Back")),
                      ActionEnumCase(value: "app-switch", title: t("argument.phone.button.appSwitch", "App Switcher")),
                  ])), device]),
            phone("phone.ui", "action.phone.ui", "Read Phone Screen Elements", symbol: "list.bullet.rectangle",
                  keywords: ["accessibility", "ui", "tree", "elements", "inspect"], cliName: "phone ui", arguments: [device]),
            phone("phone.appearance", "action.phone.appearance", "Set Phone Appearance…", symbol: "circle.lefthalf.filled",
                  keywords: ["dark mode", "light mode", "appearance", "theme"], cliName: "phone appearance",
                  arguments: [ActionArgument(name: "appearance", title: t("argument.phone.appearance", "Appearance"), kind: .enumeration([
                      ActionEnumCase(value: "light", title: t("argument.phone.appearance.light", "Light")),
                      ActionEnumCase(value: "dark", title: t("argument.phone.appearance.dark", "Dark")),
                  ])), device]),
            phone("phone.location", "action.phone.location", "Set Phone Location…", symbol: "location",
                  keywords: ["location", "gps", "geo"], cliName: "phone location",
                  arguments: [number("latitude", "argument.phone.latitude", "Latitude"),
                              number("longitude", "argument.phone.longitude", "Longitude"), device]),
            phone("phone.locale", "action.phone.locale", "Set Phone Language…", symbol: "globe",
                  keywords: ["locale", "language", "region"], cliName: "phone locale",
                  arguments: [ActionArgument(name: "locale", title: t("argument.phone.locale", "Locale"), kind: .string), device]),
            phone("phone.install", "action.phone.install", "Install App on Phone…", symbol: "square.and.arrow.down",
                  keywords: ["install", "app", "apk", "ipa"], cliName: "phone install",
                  arguments: [ActionArgument(name: "path", title: t("argument.phone.app", "App"), kind: .string), device]),
            phone("phone.launch", "action.phone.launch", "Launch App on Phone…", symbol: "play",
                  keywords: ["launch", "run", "app", "open"], cliName: "phone launch",
                  arguments: [ActionArgument(name: "app", title: t("argument.phone.bundle", "Bundle ID or Package"), kind: .string), device]),
            phone("phone.rotate", "action.phone.rotate", "Rotate Phone", symbol: "rotate.right",
                  keywords: ["rotate", "landscape", "portrait", "orientation"], cliName: "phone rotate", arguments: [device]),
            phone("phone.logs", "action.phone.logs", "Show Phone Logs", symbol: "text.alignleft",
                  keywords: ["logs", "console", "logcat", "os_log"], cliName: "phone logs", arguments: [device]),
        ]
    }

    private static func number(_ name: String, _ key: StaticString, _ english: String.LocalizationValue) -> ActionArgument {
        // Strings so points may have fractions; the handler parses them.
        ActionArgument(name: name, title: t(key, english), kind: .string)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "PhoneActions", bundle: .module)
    }
}
