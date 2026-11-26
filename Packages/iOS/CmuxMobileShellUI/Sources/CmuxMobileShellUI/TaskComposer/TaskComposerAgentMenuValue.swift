#if os(iOS)
import CmuxMobileShellModel

struct TaskComposerAgentMenuValue: Equatable {
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let isDisabled: Bool
}
#endif
