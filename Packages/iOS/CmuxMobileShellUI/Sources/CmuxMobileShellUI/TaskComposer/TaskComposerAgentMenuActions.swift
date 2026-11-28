#if os(iOS)
import CmuxMobileShellModel

struct TaskComposerAgentMenuActions {
    let selectTemplate: (MobileTaskTemplate.ID) -> Void
    let editTemplates: () -> Void
}
#endif
