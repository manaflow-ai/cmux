#if os(iOS)
import CmuxMobileShellModel

struct TaskComposerAgentMenuActions {
    let selectTemplate: (MobileTaskTemplate.ID) -> Void
    /// Applies a template + model choice as one atomic composer mutation so a
    /// combined-menu tap reconciles the submission request exactly once.
    let selectTemplateAndModel: (MobileTaskTemplate.ID, String?) -> Void
    let editTemplates: () -> Void
}
#endif
