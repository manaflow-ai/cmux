import AppKit
import Observation

@MainActor
@Observable
final class GlobalSearchPopoverPresentation {
    private(set) var presentationGeneration: Int?

    @ObservationIgnored private unowned let coordinator: GlobalSearchCoordinator
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keyEventHandler: ((GlobalSearchKeyEvent) -> Bool)?
    @ObservationIgnored private var keyMonitor: Any?

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
    }

    func popoverWillShow() {
        installKeyMonitorIfNeeded()
        generation &+= 1
        presentationGeneration = generation
    }

    func popoverDidClose() {
        presentationGeneration = nil
        keyEventHandler = nil
        removeKeyMonitor()
    }

    func handleKeyEvents(using handler: @escaping (GlobalSearchKeyEvent) -> Bool) {
        keyEventHandler = handler
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let route = MainActor.assumeIsolated {
                AppDelegate.shared?
                    .routeVisibleGlobalSearchShortcutFromLocalMonitor(event)
                    ?? .notApplicable
            }
            switch route {
            case .handled:
                return nil
            case .queryOwnsEvent:
                return event
            case .notApplicable:
                let consumed = MainActor.assumeIsolated {
                    self?.routeKeyEvent(keyEvent) ?? false
                }
                return consumed ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func routeKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard coordinator.isPaletteVisible() else { return false }

        let flags = event.modifierFlags
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            return keyEventHandler?(event) ?? false
        }

        switch event.keyCode {
        case 53:
            coordinator.dismissPalette()
            return true
        case 126 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            return keyEventHandler?(event) ?? false
        case 125 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            return keyEventHandler?(event) ?? false
        case 36, 76:
            return keyEventHandler?(event) ?? false
        default:
            if flags.contains(.command),
               !flags.contains(.option),
               !flags.contains(.control) {
                return !event.queryOwnsEditingShortcut && !isSystemCommand(event)
            }
            return false
        }
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
    }
}
