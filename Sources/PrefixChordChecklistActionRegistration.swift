import AppKit
import SwiftUI

/// SwiftUI/AppKit bridge that keeps a checklist registration current as view
/// state changes without observing a store below a lazy-list boundary.
@MainActor
struct PrefixChordChecklistActionRegistration: NSViewRepresentable {
    let registry: PrefixChordChecklistActionRegistry
    let bridge: PrefixChordChecklistActionRegistry.Bridge
    let isEligible: @MainActor () -> Bool
    let perform: @MainActor () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = RegistrationHostView(
            frame: .zero,
            registry: registry,
            bridge: bridge,
            isEligible: isEligible,
            perform: perform
        )
        view.isHidden = true
        view.updateRegistration(isEligible: isEligible, perform: perform)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RegistrationHostView)?.updateRegistration(
            isEligible: isEligible,
            perform: perform
        )
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: ()
    ) {
        (nsView as? RegistrationHostView)?.removeRegistration()
    }

    private final class RegistrationHostView: NSView {
        private let registry: PrefixChordChecklistActionRegistry
        private let bridge: PrefixChordChecklistActionRegistry.Bridge
        private var isEligible: @MainActor () -> Bool
        private var perform: @MainActor () -> Bool

        init(
            frame frameRect: NSRect,
            registry: PrefixChordChecklistActionRegistry,
            bridge: PrefixChordChecklistActionRegistry.Bridge,
            isEligible: @escaping @MainActor () -> Bool,
            perform: @escaping @MainActor () -> Bool
        ) {
            self.registry = registry
            self.bridge = bridge
            self.isEligible = isEligible
            self.perform = perform
            super.init(frame: frameRect)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRegistry()
        }

        func updateRegistration(
            isEligible: @escaping @MainActor () -> Bool,
            perform: @escaping @MainActor () -> Bool
        ) {
            self.isEligible = isEligible
            self.perform = perform
            updateRegistry()
        }

        func removeRegistration() {
            registry.unregister(bridge)
        }

        private func updateRegistry() {
            registry.update(
                bridge,
                windowNumber: window?.windowNumber,
                isEligible: isEligible,
                perform: perform
            )
        }
    }
}

@MainActor
extension View {
    func prefixChordChecklistAction(
        bridge: PrefixChordChecklistActionRegistry.Bridge,
        isEligible: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor () -> Bool
    ) -> some View {
        background {
            if let registry = AppDelegate.shared?.prefixChordChecklistActionRegistry {
                PrefixChordChecklistActionRegistration(
                    registry: registry,
                    bridge: bridge,
                    isEligible: isEligible,
                    perform: perform
                )
                .frame(width: 0, height: 0)
            }
        }
    }
}
