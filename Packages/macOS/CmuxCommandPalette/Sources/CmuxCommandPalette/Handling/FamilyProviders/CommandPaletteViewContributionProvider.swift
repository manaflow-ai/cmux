import Foundation

/// Builds the View-domain palette contribution slice (Flash Focused Panel and
/// Task Manager). The provider owns the *structure* (command identifiers, search
/// keywords, ordinal order); the localized titles and subtitles are resolved
/// app-side against the app bundle and handed in through ``Strings``.
///
/// The runnable handlers (`tabManager.triggerFocusFlash()`,
/// `TaskManagerWindowController.shared.show()`) stay app-side behind
/// ``CommandPaletteActionHandling`` because they touch app-owned live state.
public struct CommandPaletteViewContributionProvider {
    /// App-resolved display text for the View slice.
    public struct Strings: Sendable, Equatable {
        /// "Flash Focused Panel" title.
        public let triggerFlashTitle: String
        /// Subtitle shown for the flash command ("View").
        public let triggerFlashSubtitle: String
        /// "Task Manager" title.
        public let openTaskManagerTitle: String
        /// Subtitle shown for the task-manager command ("Window").
        public let openTaskManagerSubtitle: String

        /// Creates the resolved View strings.
        public init(
            triggerFlashTitle: String,
            triggerFlashSubtitle: String,
            openTaskManagerTitle: String,
            openTaskManagerSubtitle: String
        ) {
            self.triggerFlashTitle = triggerFlashTitle
            self.triggerFlashSubtitle = triggerFlashSubtitle
            self.openTaskManagerTitle = openTaskManagerTitle
            self.openTaskManagerSubtitle = openTaskManagerSubtitle
        }
    }

    /// Creates the provider. It is stateless; the catalog is baked into ``build``.
    public init() {}

    /// Assembles the View-domain contribution slice in its legacy order.
    public func build(strings: Strings) -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(strings.triggerFlashTitle),
                subtitle: constant(strings.triggerFlashSubtitle),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(strings.openTaskManagerTitle),
                subtitle: constant(strings.openTaskManagerSubtitle),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
        ]
    }
}
