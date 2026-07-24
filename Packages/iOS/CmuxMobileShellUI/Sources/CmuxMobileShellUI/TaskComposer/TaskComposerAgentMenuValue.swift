#if os(iOS)
import CmuxMobileShellModel

struct TaskComposerAgentMenuValue: Equatable {
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let modelPickerVariant: TaskComposerModelPickerVariant
    let selectedModelID: String?
    let isDisabled: Bool
}
#endif
