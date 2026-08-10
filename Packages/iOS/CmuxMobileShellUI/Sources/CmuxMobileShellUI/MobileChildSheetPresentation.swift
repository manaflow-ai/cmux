import SwiftUI

/// Connects a child-owned sheet to the root modal state machine.
struct MobileChildSheetPresentation {
    /// The root-derived presentation binding consumed by SwiftUI's sheet API.
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

    /// Begins dismissal while retaining modal ownership until `didDismiss`.
    func dismiss() {
        isPresented.wrappedValue = false
    }
}
