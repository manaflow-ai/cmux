// Send Message from anywhere (u5402, Oct 20: "Make sure we can send messages in the iMessage UI
// via right clicking"). Every row goes through one app path (`HomeMessageRouting`) into the Home
// chat's own message box and send, never a second send:
// - `home.messageTo`: Cmd+Shift+P asks for the conversation; `cmux chat send --to X [--text T]`
//   and MCP send at once when given text, else open that chat with its message box focused.
// - `home.messageAbout`: right-click a workspace, a tab or an agent chat: the Chief's chat opens
//   with a link to it in the message box.
// - `home.sendSelectionToChief` / `home.sendSelectionTo`: right-click selected text in a terminal
//   or a page (Markdown pages too): the text goes into that chat's message box as a quote.
//   A bubble's Forward… in the Home chat runs `home.sendSelectionTo` with the bubble's text.

nonisolated enum HomeMessageActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "home.messageTo", title: t("action.home.messageTo", "Send Message To…"),
                keywords: ["home", "send", "message", "chat", "imessage", "chief", "agent", "dm", "to", "write"],
                category: .window, symbol: "paperplane", surfaces: [.palette, .keyboard],
                arguments: [recipient,
                            ActionArgument(name: "text", title: t("argument.home.messageTo.text", "Message"), kind: .string,
                                           isRequired: false)],
                cliName: "chat send",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.messageAbout", title: t("action.home.messageAbout", "Send Message…"),
                keywords: ["home", "send", "message", "chat", "imessage", "chief", "agent", "workspace", "tab", "about"],
                category: .window, symbol: "paperplane", surfaces: [.contextMenu],
                targets: [.workspace, .tab],
                // Cmd+Shift+P has Send Message To… (any conversation); the CLI and MCP write the
                // workspace's link in `cmux chat send --text`.
                surfacePlan: ActionSurfacePlan(palette: .exempt(.familyMember), cli: .exempt(.familyMember), contextMenus: [
                    ContextMenuPlacement(.workspaceRow, .organize, 50, folder: .group),
                    ContextMenuPlacement(.tab, .navigate, 50),
                    ContextMenuPlacement(.agentChat, .navigate, 50),
                ])
            ),
            ActionDescriptor(
                id: "home.sendSelectionToChief", title: t("action.home.sendSelectionToChief", "Send to Chief"),
                keywords: ["home", "send", "chief", "selection", "quote", "message", "chat", "text"],
                category: .window, symbol: "paperplane", surfaces: [.contextMenu],
                arguments: [selectionText],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.familyMember), contextMenus: [
                    ContextMenuPlacement(.terminalSelection, .edit, 10),
                    ContextMenuPlacement(.browserSelection, .edit, 10),
                ])
            ),
            ActionDescriptor(
                id: "home.sendSelectionTo", title: t("action.home.sendSelectionTo", "Send To…"),
                keywords: ["home", "send", "forward", "agent", "selection", "quote", "message", "chat", "text"],
                category: .window, symbol: "arrowshape.turn.up.right", surfaces: [.contextMenu],
                arguments: [selectionText, recipient],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.familyMember), contextMenus: [
                    ContextMenuPlacement(.terminalSelection, .edit, 11),
                    ContextMenuPlacement(.browserSelection, .edit, 11),
                ])
            ),
        ]
    }

    /// Who the message goes to: a conversation id, `chief`, a person's or agent's name, a group's name.
    private static var recipient: ActionArgument {
        ActionArgument(name: "to", title: t("argument.home.messageTo.to", "To"), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.homeRecipients, pinned: []))
    }

    /// The selected text; a terminal's menu leaves it out and the App reads the selection.
    private static var selectionText: ActionArgument {
        ActionArgument(name: "text", title: t("argument.home.selection.text", "Text"), kind: .string, isRequired: false)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HomeActions", bundle: .module)
    }
}
