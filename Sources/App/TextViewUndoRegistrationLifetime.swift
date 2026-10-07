import AppKit
import ObjectiveC.runtime

/// Keeps every `NSTextView`'s undo registrations from outliving its window
/// membership.
///
/// AppKit registers text edits as `_undoRedoTextOperation:` on the text
/// view's `NSTextStorage`, in whatever undo manager the view resolves: the
/// window's shared manager, a delegate-supplied manager, or the window's
/// `NSCellUndoManager` for a field editor. Undo managers do not retain their
/// targets, and AppKit leaves those registrations behind when the text view
/// leaves the window. When cmux closes a panel, swaps a custom field editor,
/// or dismantles a SwiftUI `TextEditor`, the storage is freed while its
/// registrations stay on the window's stack. Edit > Undo in any surviving
/// editor (menu item, Cmd+Z key equivalent or context menu, all of which pass
/// through `NSApplication.cmux_sendAction`) then messages the freed storage
/// and crashes in `-[NSUndoManager undoNestedGroup]`.
///
/// The swizzle runs for every `NSTextView`, including AppKit- and
/// SwiftUI-owned ones cmux cannot subclass. When a text view is about to leave
/// its window, it removes the registrations that target its storage from the
/// undo manager it was using. Undo history for that view ends when it leaves
/// the window, so a registration can never outlive the object it messages.
enum TextViewUndoRegistrationLifetime {
    private static let didInstall: Void = {
        let targetClass: AnyClass = NSTextView.self
        let originalSelector = #selector(NSView.viewWillMove(toWindow:))
        let swizzledSelector = #selector(NSTextView.cmux_undoLifetimeViewWillMove(toWindow:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        // Add the override on NSTextView itself when AppKit only inherits
        // NSView's implementation, so the exchange never rewires NSView.
        if class_addMethod(
            targetClass,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        ) {
            class_replaceMethod(
                targetClass,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }()

    /// Installs the `NSTextView` window-departure hook once per process.
    static func install() {
        _ = didInstall
    }
}

extension NSTextView {
    @objc func cmux_undoLifetimeViewWillMove(toWindow newWindow: NSWindow?) {
        if let currentWindow = window, newWindow !== currentWindow {
            cmuxRemoveUndoRegistrationsBeforeLeaving(currentWindow)
        }
        // Calls the original implementation after the exchange.
        cmux_undoLifetimeViewWillMove(toWindow: newWindow)
    }

    /// Removes this view's text registrations from the undo manager it
    /// resolves while it is still in `currentWindow`.
    private func cmuxRemoveUndoRegistrationsBeforeLeaving(_ currentWindow: NSWindow) {
        // Text views only register edits while `allowsUndo` is on. Skipping
        // the rest keeps recycled read-only views, such as sidebar rows, off
        // the undo stack walk.
        guard allowsUndo,
              let undoManager,
              undoManager.canUndo || undoManager.canRedo else { return }
        var targets: [AnyObject] = [self]
        if let textStorage, !cmuxTextStorageIsShared(textStorage, inside: currentWindow) {
            targets.append(textStorage)
        }
        guard undoManager.isUndoing || undoManager.isRedoing else {
            for target in targets {
                undoManager.removeAllActions(withTarget: target)
            }
            return
        }
        // The view is leaving as a side effect of an undo or redo that is
        // still walking this manager's stack. Remove the registrations once
        // that operation unwinds; the closure keeps the targets alive until
        // then so the stack never holds a dangling target.
        DispatchQueue.main.async { [weak undoManager] in
            guard let undoManager else { return }
            for target in targets {
                undoManager.removeAllActions(withTarget: target)
            }
        }
    }

    /// Whether another text view in `window` lays out the same storage, in
    /// which case the storage's history still belongs to that view.
    private func cmuxTextStorageIsShared(_ textStorage: NSTextStorage, inside window: NSWindow) -> Bool {
        textStorage.layoutManagers.contains { layoutManager in
            layoutManager.textContainers.contains { container in
                guard let otherTextView = container.textView else { return false }
                return otherTextView !== self && otherTextView.window === window
            }
        }
    }
}
