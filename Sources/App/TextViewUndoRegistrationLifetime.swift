import AppKit
import ObjectiveC.runtime

/// Removes AppKit undo registrations when a text view leaves its window.
///
/// AppKit registers edits against the view's ``NSTextStorage`` in the
/// resolved window undo manager. The manager does not retain those targets,
/// and it can keep registrations after the view leaves the window. Removing
/// them at the lifecycle boundary prevents a later Undo action from messaging
/// a departed text view or storage.
@MainActor
enum TextViewUndoRegistrationLifetime {
    private static let didInstall: Void = {
        let targetClass: AnyClass = NSTextView.self
        let originalSelector = #selector(NSView.viewWillMove(toWindow:))
        let swizzledSelector = #selector(NSTextView.cmux_undoLifetimeViewWillMove(toWindow:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }

        // NSTextView inherits NSView's implementation on the supported SDKs.
        // Install the replacement on NSTextView itself so unrelated NSView
        // subclasses do not participate in this cleanup.
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

    /// Installs the text-view window-departure hook once per process.
    static func install() {
        _ = didInstall
    }
}

@MainActor
private final class TextViewUndoPendingCleanup {
    private static var associationKey: UInt8 = 0

    private weak var undoManager: UndoManager?
    private var targets: [AnyObject] = []
    private var observerTokens: [NSObjectProtocol] = []

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func add(targets newTargets: [AnyObject]) {
        for target in newTargets where !targets.contains(where: { $0 === target }) {
            targets.append(target)
        }
        installObserversIfNeeded()
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        guard let undoManager else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        observerTokens = names.map { name in
            center.addObserver(forName: name, object: undoManager, queue: nil) { [weak self] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self?.finish()
                }
            }
        }
    }

    private func finish() {
        guard let undoManager else {
            let tokens = observerTokens
            observerTokens.removeAll()
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            return
        }
        let targetsToRemove = targets
        for target in targetsToRemove {
            undoManager.removeAllActions(withTarget: target)
        }

        let tokens = observerTokens
        observerTokens.removeAll()
        targets.removeAll()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        objc_setAssociatedObject(
            undoManager,
            &Self.associationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func pendingCleanup(for undoManager: UndoManager) -> TextViewUndoPendingCleanup {
        if let pending = objc_getAssociatedObject(undoManager, &associationKey)
            as? TextViewUndoPendingCleanup {
            return pending
        }
        let pending = TextViewUndoPendingCleanup(undoManager: undoManager)
        objc_setAssociatedObject(
            undoManager,
            &associationKey,
            pending,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return pending
    }
}

@MainActor
extension NSTextView {
    @objc func cmux_undoLifetimeViewWillMove(toWindow newWindow: NSWindow?) {
        if let currentWindow = window, newWindow !== currentWindow {
            cmuxRemoveUndoRegistrationsBeforeLeaving(currentWindow)
        }
        // Calls the original implementation after the exchange.
        cmux_undoLifetimeViewWillMove(toWindow: newWindow)
    }

    /// Removes registrations for this view and its storage while membership
    /// in ``currentWindow`` still resolves the correct undo manager.
    private func cmuxRemoveUndoRegistrationsBeforeLeaving(_ currentWindow: NSWindow) {
        guard allowsUndo,
              let undoManager,
              undoManager.canUndo || undoManager.canRedo else {
            return
        }

        var targets: [AnyObject] = [self]
        if let textStorage, !cmuxTextStorageIsShared(textStorage, inside: currentWindow) {
            targets.append(textStorage)
        }

        // Undo/redo posts its completion notification after the stack has
        // finished invoking targets. Hold cleanup at that explicit lifecycle
        // boundary instead of mutating an active undo stack.
        if undoManager.isUndoing || undoManager.isRedoing {
            TextViewUndoPendingCleanup.pendingCleanup(for: undoManager).add(targets: targets)
            return
        }

        for target in targets {
            undoManager.removeAllActions(withTarget: target)
        }
    }

    /// Reports whether another text view in `window` still uses this storage.
    private func cmuxTextStorageIsShared(_ textStorage: NSTextStorage, inside window: NSWindow) -> Bool {
        textStorage.layoutManagers.contains { layoutManager in
            layoutManager.textContainers.contains { container in
                guard let otherTextView = container.textView else { return false }
                return otherTextView !== self && otherTextView.window === window
            }
        }
    }
}
