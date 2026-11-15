public import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

// Customize… (`customize.open`, the palette and the app menu): customize cmux by asking with no
// terminal (cmuxterm-hq `plans/cmux-next/customize-by-asking/DESIGN.md`). It runs New Agent
// Chat's own path with one more argument, the draft `/customize `: a new chat where New Agent
// Chat opens one, its composer starting with the command, so the person types the wish and
// presses Return. The chat's `/customize` (webviews `customizeCommand.ts`) asks its agent, which
// changes the real files while the window shows the preview; `/customize apply`, `discard` and
// `rollback` in the same chat run those `cmux customize` verbs. Nothing here implements the flow.

extension ActionID {
    /// Customize…: a new agent chat whose composer starts with ``AgentPaneSeed/customizeDraft``.
    public static let customizeOpen: ActionID = "customize.open"
}

extension AgentPaneSeed {
    /// The composer's first text for Customize…: the chat command the ask goes through. Shown,
    /// never sent by itself.
    public static let customizeDraft = "/customize "
}

extension ActionInvocation {
    /// This invocation as New Agent Chat's for Customize…: the same target and origin, with
    /// ``AgentPaneSeed/customizeDraft`` as the `draft` argument the new chat's seed takes. A caller's
    /// own `draft` (Settings search's "Ask cmux to do this": `/customize WORDS`) is kept.
    public var customizing: ActionInvocation {
        var invocation = self
        if invocation.arguments["draft"]?.stringValue?.isEmpty ?? true {
            invocation.arguments["draft"] = .string(AgentPaneSeed.customizeDraft(for: invocation["element"]?.stringValue.flatMap(CustomizeElement.named)))
        }
        return invocation
    }
}

extension AgentPaneSeed {
    /// The composer's first text for Customize… about `element` (the right-click row, the Customize
    /// Inspector's Change This…): the command and the part's name, so the wish follows it
    /// (`/customize Tab Bar: `). Without one, ``customizeDraft``.
    public static func customizeDraft(for element: CustomizeElement?) -> String {
        element.map { customizeDraft + $0.title + ": " } ?? customizeDraft
    }
}

extension ActionRegistry {
    /// Reset Element to Defaults (`customize.reset`): every setting the element map names for the
    /// `element` argument goes back to its default (the key is removed), the Customize Inspector's
    /// Reset. Only those keys; a key the schema retired or never had is skipped.
    func bindCustomizeReset(settings: @escaping @MainActor () -> SettingsController?) -> Bool {
        bindEffect(ActionID(rawValue: CustomizeElement.resetActionID)) { invocation in
            guard let element = invocation["element"]?.stringValue.flatMap(CustomizeElement.named) else { return .done }
            guard let controller = settings() else { return .done }
            let writer = SettingWriter(invocation.origin)
            let paths = element.settings.map { $0.split(separator: ".").map(String.init) }
            return .applied(result: {
                for path in paths where SettingsSchema.descriptor(for: path) != nil {
                    do { try await controller.setSetting(at: path, to: nil, by: writer) } catch {
                        return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error)))
                    }
                }
                return .success([:])
            })
        }
    }
}
