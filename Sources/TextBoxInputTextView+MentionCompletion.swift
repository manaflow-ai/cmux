import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Mention Completion
extension TextBoxInputTextView {
    var mentionCompletionController: TextBoxMentionCompletionController {
        if let mentionCompletionControllerStorage {
            return mentionCompletionControllerStorage
        }
        let controller = TextBoxMentionCompletionController()
        controller.onStateChanged = { [weak self] in
            self?.syncMentionCompletionPopover()
        }
        mentionCompletionControllerStorage = controller
        return controller
    }

    func refreshMentionCompletions() {
        let query = TextBoxMentionCompletionDetector.query(
            in: attributedString().string,
            selectedRange: selectedRange()
        )
        mentionCompletionController.refresh(
            for: query,
            rootDirectory: completionRootDirectory
        )
    }

    func warmMentionCompletionIndexesIfNeeded() {
        let rootDirectory = completionRootDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = rootDirectory?.isEmpty == false ? rootDirectory : nil
        guard warmedMentionCompletionRootDirectory != cacheKey else { return }
        warmedMentionCompletionRootDirectory = cacheKey
        mentionCompletionWarmupTask?.cancel()
        mentionCompletionWarmupTask = Task {
            await TextBoxMentionIndexStore.shared.warmIndexes(rootDirectory: cacheKey)
        }
    }

    func handleMentionCompletionKeyEvent(_ event: NSEvent) -> Bool {
        guard mentionCompletionController.isActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.option) else {
            return false
        }

        if flags.contains(.control) {
            guard let key = mentionCompletionControlNavigationKey(for: event) else { return false }
            switch key {
            case "p", "k":
                if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                    dismissMentionCompletions()
                    return false
                }
                // Only claim the navigation keys once there are rows to move through;
                // otherwise (active query still loading or zero hits) let them fall
                // through to normal text editing instead of being silently swallowed.
                guard mentionCompletionController.hasCurrentSuggestions else { return false }
                mentionCompletionController.moveSelection(delta: -1)
                return true
            case "n", "j":
                if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                    dismissMentionCompletions()
                    return false
                }
                guard mentionCompletionController.hasCurrentSuggestions else { return false }
                mentionCompletionController.moveSelection(delta: 1)
                return true
            default:
                return false
            }
        }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case kVK_DownArrow:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !flags.contains(.shift) else { return false }
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            if shouldBypassMentionCompletionReturnAcceptance() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case kVK_Tab:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case kVK_Escape:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.shouldShowPopover else { return false }
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    func handleMentionCompletionCommand(_ commandSelector: Selector) -> Bool {
        guard mentionCompletionController.isActive else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            if shouldBypassMentionCompletionReturnAcceptance() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case #selector(NSResponder.insertTab(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case #selector(NSResponder.cancelOperation(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.shouldShowPopover else { return false }
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    private func shouldBypassHiddenMentionCompletionKeyboardInteraction() -> Bool {
        guard let window else { return false }
        guard NSApp.isActive,
              window.isKeyWindow,
              window.firstResponder === self,
              mentionCompletionPanel?.isVisible == true else {
            return true
        }
        return false
    }

    private func shouldBypassMentionCompletionReturnAcceptance() -> Bool {
        guard let query = mentionCompletionController.activeQuery,
              query.kind == .skill,
              query.query.isEmpty else {
            return false
        }
        return true
    }

    @discardableResult
    private func acceptMentionCompletion(_ explicitSuggestion: TextBoxMentionSuggestion? = nil) -> Bool {
        guard mentionCompletionController.hasCurrentSuggestions,
              let query = mentionCompletionController.activeQuery,
              let suggestion = explicitSuggestion ?? mentionCompletionController.selectedSuggestion,
              explicitSuggestion == nil ||
                  mentionCompletionController.suggestions.contains(where: { $0.id == suggestion.id }),
              isValidSelectedRange(query.range),
              shouldChangeText(in: query.range, replacementString: suggestion.insertionText) else {
            return false
        }

        let replacement = mentionCompletionReplacementText(
            for: suggestion,
            replacing: query.range
        )
        textStorage?.replaceCharacters(
            in: query.range,
            with: NSAttributedString(string: replacement, attributes: currentTextAttributes())
        )
        let insertionLocation = query.location + (replacement as NSString).length
        setSelectedRange(NSRange(location: insertionLocation, length: 0))
        dismissMentionCompletions()
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        scrollRangeToVisible(NSRange(location: insertionLocation, length: 0))
        return true
    }

    private func mentionCompletionReplacementText(
        for suggestion: TextBoxMentionSuggestion,
        replacing range: NSRange
    ) -> String {
        let nsText = attributedString().string as NSString
        let nextLocation = NSMaxRange(range)
        guard nextLocation < nsText.length else {
            return suggestion.insertionText + " "
        }

        let nextCharacter = nsText.substring(with: NSRange(location: nextLocation, length: 1))
        if nextCharacter.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return suggestion.insertionText
        }
        return suggestion.insertionText + " "
    }

    private func syncMentionCompletionPopover() {
        guard mentionCompletionController.shouldShowPopover else {
            dismissMentionCompletionPopoverOnly()
            return
        }
        guard NSApp.isActive,
              window?.firstResponder === self,
              let parentWindow = window,
              parentWindow.isKeyWindow,
              let anchorRect = mentionCompletionAnchorRect() else {
            dismissMentionCompletionPopoverOnly()
            return
        }
        updateMentionCompletionWindowObservers(for: parentWindow)

        let showsLoadingRow = mentionCompletionController.suggestions.isEmpty &&
            mentionCompletionController.isLoadingSuggestions
        let rowCount = showsLoadingRow ? 1 : mentionCompletionController.suggestions.count
        let maxVisibleRows = 12
        let visibleRows = min(rowCount, maxVisibleRows)
        let rowHeight: CGFloat = 25
        let contentSize = NSSize(
            width: 360,
            height: CGFloat(visibleRows) * rowHeight + 8
        )
        let host: NSHostingView<TextBoxMentionCompletionPopoverView>
        if let existingHost = mentionCompletionPanelHost {
            existingHost.rootView = mentionCompletionPopoverView()
            host = existingHost
        } else {
            host = NSHostingView(rootView: mentionCompletionPopoverView())
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            mentionCompletionPanelHost = host
        }
        host.frame = NSRect(origin: .zero, size: contentSize)

        let panel = mentionCompletionPanel ?? makeMentionCompletionPanel(host: host)
        if panel.contentView !== host {
            panel.contentView = host
        }
        panel.setContentSize(contentSize)
        let targetOrigin = mentionCompletionPanelOrigin(
            anchorRect: anchorRect,
            contentSize: contentSize
        )
        if mentionCompletionPanelOriginNeedsUpdate(from: panel.frame.origin, to: targetOrigin) {
            panel.setFrameOrigin(targetOrigin)
        }

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func makeMentionCompletionPanel(
        host: NSHostingView<TextBoxMentionCompletionPopoverView>
    ) -> TextBoxMentionCompletionPanel {
        let panel = TextBoxMentionCompletionPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.textbox.mentionCompletionPanel")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = host
        mentionCompletionPanel = panel
        return panel
    }

    private func updateMentionCompletionWindowObservers(for parentWindow: NSWindow) {
        if mentionCompletionObservedWindow === parentWindow,
           !mentionCompletionWindowObserverTokens.isEmpty {
            return
        }

        removeMentionCompletionWindowObservers()
        mentionCompletionObservedWindow = parentWindow

        let notificationNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didResignKeyNotification
        ]
        let notificationCenter = NotificationCenter.default
        mentionCompletionWindowObserverTokens = notificationNames.map { notificationName in
            notificationCenter.addObserver(
                forName: notificationName,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleMentionCompletionPanelReposition()
            }
        }
    }

    func removeMentionCompletionWindowObservers() {
        let notificationCenter = NotificationCenter.default
        for observerToken in mentionCompletionWindowObserverTokens {
            notificationCenter.removeObserver(observerToken)
        }
        mentionCompletionWindowObserverTokens = []
        mentionCompletionObservedWindow = nil
        mentionCompletionRepositionIsScheduled = false
    }

    func scheduleMentionCompletionPanelReposition() {
        guard mentionCompletionPanel?.isVisible == true,
              !mentionCompletionRepositionIsScheduled else {
            return
        }
        mentionCompletionRepositionIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self,
                  self.mentionCompletionRepositionIsScheduled else {
                return
            }
            self.mentionCompletionRepositionIsScheduled = false
            self.repositionMentionCompletionPanelIfNeeded()
        }
    }

    private func repositionMentionCompletionPanelIfNeeded() {
        guard mentionCompletionController.shouldShowPopover,
              let panel = mentionCompletionPanel,
              panel.isVisible,
              NSApp.isActive,
              window?.firstResponder === self,
              let parentWindow = window,
              parentWindow.isKeyWindow,
              let anchorRect = mentionCompletionAnchorRect(),
              let contentSize = mentionCompletionPanelContentSize(panel),
              contentSize.width > 0,
              contentSize.height > 0 else {
            dismissMentionCompletionPopoverOnly()
            return
        }

        updateMentionCompletionWindowObservers(for: parentWindow)
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        let targetOrigin = mentionCompletionPanelOrigin(
            anchorRect: anchorRect,
            contentSize: contentSize
        )
        if mentionCompletionPanelOriginNeedsUpdate(from: panel.frame.origin, to: targetOrigin) {
            panel.setFrameOrigin(targetOrigin)
        }
    }

    private func mentionCompletionPanelContentSize(_ panel: TextBoxMentionCompletionPanel) -> NSSize? {
        if let contentView = panel.contentView {
            return contentView.bounds.size
        }
        return panel.contentRect(forFrameRect: panel.frame).size
    }

    private func mentionCompletionPanelOriginNeedsUpdate(
        from currentOrigin: NSPoint,
        to targetOrigin: NSPoint
    ) -> Bool {
        abs(currentOrigin.x - targetOrigin.x) > 0.5 ||
            abs(currentOrigin.y - targetOrigin.y) > 0.5
    }

    private func mentionCompletionPanelOrigin(
        anchorRect: NSRect,
        contentSize: NSSize
    ) -> NSPoint {
        let anchorInWindow = convert(anchorRect, to: nil)
        guard let window else {
            return .zero
        }
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let screenFrame = window.screen?.visibleFrame ?? anchorOnScreen
        var x = anchorOnScreen.minX
        let gap: CGFloat = 4
        var y = anchorOnScreen.minY - contentSize.height - gap
        if y < screenFrame.minY + 8 {
            y = anchorOnScreen.maxY + gap
        }
        let maxX = screenFrame.maxX - contentSize.width - 8
        if x > maxX { x = max(screenFrame.minX + 8, maxX) }
        if x < screenFrame.minX + 8 { x = screenFrame.minX + 8 }
        return NSPoint(x: x, y: y)
    }

    private func mentionCompletionPopoverView() -> TextBoxMentionCompletionPopoverView {
        TextBoxMentionCompletionPopoverView(
            suggestions: mentionCompletionController.suggestions,
            selectionIndex: mentionCompletionController.selectionIndex,
            searchTerm: mentionCompletionController.activeQuery?.query ?? "",
            isLoading: mentionCompletionController.isLoadingSuggestions,
            onSelect: { [weak self] suggestion in
                self?.window?.makeFirstResponder(self)
                self?.acceptMentionCompletion(suggestion)
            }
        )
    }

    private func mentionCompletionAnchorRect() -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let length = attributedString().length
        guard length > 0 else {
            return NSRect(
                x: textContainerOrigin.x,
                y: textContainerOrigin.y,
                width: 1,
                height: font?.pointSize ?? 14
            )
        }

        let queryCursor = mentionCompletionController.activeQuery.map { NSMaxRange($0.range) }
        let cursor = min(max(0, queryCursor ?? selectedRange().location), length)
        let characterLocation = max(0, min(cursor, length - 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterLocation, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if cursor > characterLocation {
            rect.origin.x = rect.maxX
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = 1
        rect.size.height = max(rect.height, font?.pointSize ?? 14)
        return rect
    }

    func dismissMentionCompletions() {
        mentionCompletionControllerStorage?.clear()
        dismissMentionCompletionPopoverOnly()
    }

    private func dismissMentionCompletionPopoverOnly() {
        removeMentionCompletionWindowObservers()
        if let panel = mentionCompletionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        mentionCompletionPanel = nil
        mentionCompletionPanelHost = nil
    }

#if DEBUG
    func debugSetMentionCompletionState(
        query: TextBoxMentionQuery?,
        suggestions: [TextBoxMentionSuggestion],
        rootDirectory: String? = nil,
        isLoading: Bool = false
    ) {
        mentionCompletionController.debugSetState(
            query: query,
            suggestions: suggestions,
            rootDirectory: rootDirectory,
            isLoading: isLoading
        )
    }

    func debugMentionSuggestionCount() -> Int {
        mentionCompletionController.debugSuggestionCount
    }

    func debugMentionSuggestionTitles() -> [String] {
        mentionCompletionController.debugSuggestionTitles
    }

    func debugMentionSuggestionsAreCurrent() -> Bool {
        mentionCompletionController.debugHasCurrentSuggestions
    }

    func debugMentionCompletionsShouldShowPopover() -> Bool {
        mentionCompletionController.debugShouldShowPopover
    }

    func debugMentionSelectionIndex() -> Int {
        mentionCompletionController.selectionIndex
    }

    func debugAcceptMentionCompletion() -> Bool {
        acceptMentionCompletion()
    }

    func debugAcceptMentionCompletion(suggestion: TextBoxMentionSuggestion) -> Bool {
        acceptMentionCompletion(suggestion)
    }

    func debugControlKey(for event: NSEvent) -> String? {
        controlKey(for: event)
    }

    func debugMentionCompletionControlNavigationKey(for event: NSEvent) -> String? {
        mentionCompletionControlNavigationKey(for: event)
    }
#endif

    private func mentionCompletionControlNavigationKey(for event: NSEvent) -> String? {
        let normalizedKey = KeyboardLayout.normalizedCharacters(for: event).lowercased()
        if normalizedKey.count == 1, normalizedKey.allSatisfy(\.isASCII) {
            return normalizedKey
        }
        return controlKey(for: event)
    }

}
