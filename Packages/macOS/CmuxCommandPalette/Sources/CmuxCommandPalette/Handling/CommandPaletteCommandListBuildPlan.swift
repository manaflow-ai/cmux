import Foundation

/// Assembles the ordered, context-filtered list of runnable palette commands
/// from the declarative contribution catalog.
///
/// Building the command list is a pure transform over four host-resolved inputs
/// per contribution: any `cmux.json` configuration override, the `when` /
/// `enablement` gates evaluated against the context snapshot, the resolved
/// keyboard-shortcut hint, and the registered handler. The host owns those
/// resolutions because they read live config/shortcut stores and app behavior;
/// this value owns the *iteration, filtering, override-merge, ranking, and
/// `CommandPaletteCommand` construction*, reproducing the legacy
/// `ContentView.commandPaletteCommands(commandsContext:)` loop byte-for-byte so
/// the assembled list is faithful while the loop is unit-testable in the palette
/// domain.
///
/// ## Faithful mapping
///
/// The legacy loop, per contribution, was:
///
/// 1. Resolve the configured palette action; if it exists and is not
///    `palette`-enabled, skip the contribution.
/// 2. Skip unless both `when` and `enablement` pass for the context.
/// 3. Resolve the handler; if missing, `assertionFailure` and skip.
/// 4. Append a ``CommandPaletteCommand`` whose title/subtitle/keywords prefer
///    the configured override and whose `shortcutHint` is the host-resolved
///    hint, assigning monotonically increasing ranks.
public struct CommandPaletteCommandListBuildPlan {
    /// The assembled, ranked, context-filtered commands.
    public let commands: [CommandPaletteCommand]

    /// Builds the command list.
    ///
    /// - Parameters:
    ///   - contributions: The ordered contribution catalog.
    ///   - context: The context snapshot the `when` / `enablement` gates read.
    ///   - resolveConfigOverride: Resolves the `cmux.json` override for a command
    ///     id, or `nil` when none is configured.
    ///   - resolveShortcutHint: Resolves the shortcut-hint glyph for a
    ///     contribution in the given context.
    ///   - resolveHandler: Resolves the runnable handler for a command id, or
    ///     `nil` when none is registered (a programmer error the host reports).
    ///   - onMissingHandler: Invoked with the offending command id when a
    ///     contribution survives filtering but has no registered handler;
    ///     mirrors the legacy `assertionFailure` and is then skipped.
    public init(
        contributions: [CommandPaletteCommandContribution],
        context: CommandPaletteContextSnapshot,
        resolveConfigOverride: (String) -> CommandPaletteConfigActionOverride?,
        resolveShortcutHint: (CommandPaletteCommandContribution, CommandPaletteContextSnapshot) -> String?,
        resolveHandler: (String) -> (() -> Void)?,
        onMissingHandler: (String) -> Void
    ) {
        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            let configuredPaletteAction = resolveConfigOverride(contribution.commandId)
            if let configuredPaletteAction, !configuredPaletteAction.palette {
                continue
            }
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = resolveHandler(contribution.commandId) else {
                onMissingHandler(contribution.commandId)
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: configuredPaletteAction?.title ?? contribution.title(context),
                    subtitle: configuredPaletteAction?.subtitle ?? contribution.subtitle(context),
                    shortcutHint: resolveShortcutHint(contribution, context),
                    kindLabel: nil,
                    keywords: configuredPaletteAction?.keywords.isEmpty == false
                        ? configuredPaletteAction?.keywords ?? contribution.keywords
                        : contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        self.commands = commands
    }
}
