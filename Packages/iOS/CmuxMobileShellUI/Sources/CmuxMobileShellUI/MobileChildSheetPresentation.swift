import SwiftUI

/// Connects a child-owned sheet to its local identity and the root modal state machine.
struct MobileChildSheetPresentation {
    /// The presentation binding consumed by SwiftUI's sheet API.
    let isPresented: Binding<Bool>
    /// Completes the state transition only after the child sheet leaves screen.
    let didDismiss: () -> Void

    /// Creates a child-sheet presentation handle.
    ///
    /// - Parameters:
    ///   - isPresented: The root-derived binding for this child presentation.
    ///   - didDismiss: The callback invoked from the sheet's `onDismiss` hook.
    init(
        isPresented: Binding<Bool> = .constant(false),
        didDismiss: @escaping () -> Void = {}
    ) {
        self.isPresented = isPresented
        self.didDismiss = didDismiss
    }

    /// Requests ownership of the shared modal slot for this child sheet.
    @discardableResult
    func present() -> Bool {
        isPresented.wrappedValue = true
        return isPresented.wrappedValue
    }

    /// Requests modal ownership, then runs side effects only after acquisition.
    ///
    /// Use this overload when a presentation owns payload, persistence, or
    /// fetch work that must remain unchanged if another modal denies the request.
    @discardableResult
    func present(_ onAcquired: () -> Void) -> Bool {
        guard present() else { return false }
        onAcquired()
        return true
    }

    /// Begins dismissal while retaining modal ownership until `didDismiss`.
    func dismiss() {
        isPresented.wrappedValue = false
    }

    /// Combines a root occupancy grant with one presenter's local identity.
    ///
    /// Equal child enum cases intentionally share the root grant, so the local
    /// binding distinguishes which concrete sheet or popover requested it. A
    /// denied request never mutates local state, and root ownership remains held
    /// until the active presenter's real dismissal callback.
    func coordinated(with localIsPresented: Binding<Bool>) -> MobileChildSheetPresentation {
        let rootIsPresented = isPresented
        let rootDidDismiss = didDismiss
        return MobileChildSheetPresentation(
            isPresented: Binding(
                get: {
                    localIsPresented.wrappedValue
                        && rootIsPresented.wrappedValue
                },
                set: { shouldPresent in
                    if shouldPresent {
                        if localIsPresented.wrappedValue {
                            return
                        }
                        guard !rootIsPresented.wrappedValue else {
                            return
                        }
                        rootIsPresented.wrappedValue = true
                        guard rootIsPresented.wrappedValue else { return }
                        localIsPresented.wrappedValue = true
                    } else {
                        guard localIsPresented.wrappedValue else {
                            return
                        }
                        localIsPresented.wrappedValue = false
                        rootIsPresented.wrappedValue = false
                    }
                }
            ),
            didDismiss: {
                localIsPresented.wrappedValue = false
                rootDidDismiss()
            }
        )
    }
}
