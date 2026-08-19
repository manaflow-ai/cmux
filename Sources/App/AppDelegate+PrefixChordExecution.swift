import AppKit
import CmuxSettings

/// Executes a binding after ``ShortcutPrefixChordCoordinator`` has consumed
/// its leader stroke.
///
/// The ordinary dispatcher remains the single source of truth for app-owned
/// actions. A small focused-action fallback covers responders whose state
/// machine intentionally lives below AppDelegate (for example a WebKit viewer
/// or a checklist view with a highlighted row). This keeps the global leader
/// layer from duplicating those actions or asking a responder to reconstruct a
/// leader stroke that it never received.
extension AppDelegate {
    @discardableResult
    func executeResolvedPrefixChordBinding(
        _ binding: ShortcutPrefixChordBinding,
        event: NSEvent
    ) -> Bool {
        // The router snapshots the table at the leader stroke. Settings or
        // focus can change before the suffix arrives; verify the target still
        // owns this exact two-stroke binding so a stale chord cannot fall into
        // a different action's generic matcher.
        guard prefixChordBindingIsStillCurrent(binding, event: event) else {
            return false
        }

        // Config-defined actions have their own resolved executor (including
        // trust prompts and workspace/terminal command targets). Dispatch
        // directly when the id is not a built-in ShortcutAction, avoiding a
        // second scan that could accidentally select another configured item.
        if KeyboardShortcutSettings.Action(rawValue: binding.actionID) == nil,
           let context = preferredMainWindowContextForShortcutRouting(event: event),
           let configuredAction = configuredCmuxShortcutActions(for: context)
               .first(where: { $0.id == binding.actionID }) {
            return executeConfiguredCmuxAction(
                configuredAction,
                context: context,
                preferredWindow: resolvedShortcutEventWindow(event)
                    ?? event.window
                    ?? shortcutRoutingActiveWindow
            )
        }

        let resolvedPrefix = ShortcutStroke(
            cmuxSettingsShortcutStroke: binding.firstStroke
        )
        if handleCustomShortcut(
            event: event,
            skipPrefixChordRouting: true,
            resolvedPrefixStroke: resolvedPrefix
        ) {
            return true
        }

        guard let action = KeyboardShortcutSettings.Action(rawValue: binding.actionID) else {
            // Configured cmux actions are already covered by the generic
            // dispatcher above. Unknown ids fail closed rather than guessing
            // at a plugin or menu target.
            return false
        }
        return executeFocusedPrefixChordAction(action, event: event)
    }

    private func prefixChordBindingIsStillCurrent(
        _ binding: ShortcutPrefixChordBinding,
        event: NSEvent
    ) -> Bool {
        if let action = KeyboardShortcutSettings.Action(rawValue: binding.actionID) {
            guard let shortcut = KeyboardShortcutSettings.shortcutIfBound(for: action),
                  shortcut.hasChord,
                  KeyboardShortcutSettings.effectiveWhenClause(for: action)
                      .evaluate(shortcutEventFocusContext(event).shortcutContext) else {
                return false
            }
            return prefixChordShortcutMatches(
                shortcut,
                binding: binding,
                numbered: action.usesNumberedDigitMatching
            )
        }

        guard let context = preferredMainWindowContextForShortcutRouting(event: event),
              let configuredAction = configuredCmuxShortcutActions(for: context)
                  .first(where: { $0.id == binding.actionID }),
              let shortcut = configuredAction.shortcut,
              shortcut.hasChord else {
            return false
        }
        return prefixChordShortcutMatches(shortcut, binding: binding, numbered: false)
    }

    private func prefixChordShortcutMatches(
        _ shortcut: StoredShortcut,
        binding: ShortcutPrefixChordBinding,
        numbered: Bool
    ) -> Bool {
        guard shortcut.firstStroke.isRoutingEquivalent(to: binding.firstStroke),
              let secondStroke = shortcut.secondStroke else {
            return false
        }
        if numbered,
           let digit = Int(secondStroke.key),
           (1...9).contains(digit),
           let eventDigit = Int(binding.secondStroke.key),
           (1...9).contains(eventDigit) {
            return secondStroke.command == binding.secondStroke.command
                && secondStroke.shift == binding.secondStroke.shift
                && secondStroke.option == binding.secondStroke.option
                && secondStroke.control == binding.secondStroke.control
        }
        return secondStroke.isRoutingEquivalent(to: binding.secondStroke)
    }

    private func executeFocusedPrefixChordAction(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        switch action {
        case .saveFilePreview:
            guard let textView = prefixChordResponder(in: event) as? SavingTextView else {
                return false
            }
            return textView.performPrefixChordSave()

        case .cycleTextBoxSubmitAction:
            guard let textView = prefixChordResponder(in: event) as? TextBoxInputTextView else {
                return false
            }
            return textView.performPrefixChordSubmitActionCycle()

        case .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return executeFocusedFileExplorerPrefixChordAction(event: event)

        case .toggleChecklistItemComplete:
            return prefixChordChecklistActionRegistry.perform(
                action,
                event: event
            )

        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .diffViewerNextFile,
             .diffViewerPreviousFile:
            return executeFocusedViewerPrefixChordAction(action, event: event)

        default:
            return false
        }
    }

    /// File-explorer selection shortcuts normally execute in the focused
    /// outline/search responder rather than in AppDelegate. The global prefix
    /// monitor consumes the leader before that responder sees it, so re-enter
    /// its existing shared handler with the active suffix marker in place.
    private func executeFocusedFileExplorerPrefixChordAction(event: NSEvent) -> Bool {
        let window = resolvedShortcutEventWindow(event)
            ?? event.window
            ?? shortcutRoutingActiveWindow
        guard let firstResponder = window?.firstResponder else { return false }
        return firstPrefixChordCandidate(startingAt: firstResponder) { candidate in
            if let outline = candidate as? FileExplorerNSOutlineView,
               outline.handleOpenSelectionShortcut(event) {
                return true
            }
            if let results = candidate as? FileExplorerSearchResultsTableView,
               results.handleOpenSelectionShortcut(event) {
                return true
            }
            if let searchField = candidate as? FileExplorerSearchField,
               searchField.handleOpenSelectionShortcut(event) {
                return true
            }
            return nil
        } ?? false
    }

    private func executeFocusedViewerPrefixChordAction(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        let focus = shortcutEventFocusContext(event)
        if let browserWebView = focus.browserPanel?.webView as? CmuxWebView {
            return browserWebView.performResolvedDiffViewerNavigation(action, event: event)
        }
        if let markdownWebView = focus.markdownPanel?.rendererSession.webView {
            return markdownWebView.performResolvedViewerNavigation(action, event: event)
        }
        return false
    }

    private func prefixChordResponder(in event: NSEvent) -> NSResponder? {
        let window = resolvedShortcutEventWindow(event)
            ?? event.window
            ?? shortcutRoutingActiveWindow
        guard let responder = window?.firstResponder else { return nil }
        if responder is SavingTextView || responder is TextBoxInputTextView {
            return responder
        }
        return firstPrefixChordCandidate(startingAt: responder) { candidate in
            if candidate is SavingTextView || candidate is TextBoxInputTextView {
                return candidate
            }
            return nil
        }
    }

    /// Walks the responder chain and hosted view tree once, returning the first
    /// candidate accepted by `transform`. Cycle protection keeps AppKit's
    /// bidirectional responder/view graph bounded.
    private func firstPrefixChordCandidate<T>(
        startingAt responder: NSResponder,
        _ transform: (NSResponder) -> T?
    ) -> T? {
        var pending: [NSResponder] = [responder]
        var visited = Set<ObjectIdentifier>()
        while let candidate = pending.popLast() {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else {
                continue
            }
            if let match = transform(candidate) {
                return match
            }
            if let next = candidate.nextResponder {
                pending.append(next)
            }
            // Some hosted editors are reachable through the view tree but not
            // through the responder chain exposed by the current first responder.
            if let view = candidate as? NSView, let superview = view.superview {
                pending.append(superview)
            }
        }
        return nil
    }
}
