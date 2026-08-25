import CmuxMobileShell

/// The single iOS modal owner and its root-sheet and child-sheet transitions.
///
/// Root presentations share one SwiftUI sheet host. Child presentations claim
/// that same logical modal slot while retaining the sheet modifier nearest
/// their content. A dismissing child keeps ownership until its `onDismiss`
/// callback, preventing a root sheet from competing with UIKit's transition.
struct MobileRootPresentationState: Equatable {
    /// Presentations owned by the workspace list or one of its row actions.
    enum WorkspaceListPresentation: Equatable, CaseIterable {
        case terminalShortcutsSettings
        case settings
        case deviceTree
        case viewOptions
        case macUpdateHint
        case customization
        case changes
    }

    /// Presentations reachable after navigating into a workspace detail.
    enum WorkspaceDetailPresentation: Equatable, CaseIterable {
        case feedbackComposer
        case terminalText
        case workspaceChanges
        case customization
        case terminalArtifactFiles
        case alternateScreenExplanation
    }

    /// A child-owned sheet that participates in the shared modal slot.
    enum ChildPresentation: Equatable {
        case workspaceDeviceTree
        case workspaceTaskComposer
        case disconnectedSetupHelp
        case workspaceList(WorkspaceListPresentation)
        case workspaceDetail(WorkspaceDetailPresentation)
    }

    /// The content or transition currently holding the shared modal slot.
    enum Presentation: Equatable {
        case autoConnectMigrationIntroduction
        case settings
        case computers
        case pairing(PairingPresentation)
        case child(ChildPresentation)
        case dismissingChild(
            ChildPresentation,
            pendingPairing: PairingPresentation?
        )
    }

    /// Every presentation mutation accepted by the root coordinator.
    enum Action: Equatable {
        case presentAutoConnectMigrationIfIdle
        case useAutoConnect
        case setUpTailscale(status: MobileTailscaleSetupStatus)
        case presentSettings
        case dismissSettings(presentAutoConnectMigration: Bool)
        case presentComputers
        case dismissComputers
        case presentPairing(PairingPresentation)
        case presentChild(ChildPresentation)
        case dismissChild(ChildPresentation)
        case childDidDismiss(ChildPresentation)
        case authenticationChanged(isAuthenticated: Bool)
        case migrationEligibilityChanged(isEligible: Bool)
        case sheetDidRequestDismissal
        case dismissPairing
    }

    /// Side effects the owning view performs after a synchronous transition.
    enum Effect: Equatable {
        case none
        case acknowledgeAutoConnectMigration
        case useAutoConnect
        case setUpTailscale(requiresPairing: Bool)
        case finishPairing
        case retryAutoConnectMigration
    }

    /// The current modal owner or transition, or `nil` when the slot is idle.
    private(set) var presentation: Presentation? = nil

    /// Whether no root or child presentation currently owns the modal slot.
    var isIdle: Bool {
        presentation == nil
    }

    /// Whether the root SwiftUI sheet host should be presented.
    var isRootSheetPresented: Bool {
        switch presentation {
        case .autoConnectMigrationIntroduction,
             .settings,
             .computers,
             .pairing:
            true
        case .child, .dismissingChild, nil:
            false
        }
    }

    /// Returns whether the requested child currently owns a visible sheet.
    func isPresentingChild(_ child: ChildPresentation) -> Bool {
        presentation == .child(child)
    }

    /// Applies one shared presentation action and returns any required side effect.
    ///
    /// Interactive introduction dismissal acknowledges the migration. Child
    /// dismissal holds the modal slot until `onDismiss`, while auth loss clears
    /// it immediately without acknowledging a pending migration.
    @discardableResult
    mutating func apply(_ action: Action) -> Effect {
        switch action {
        case .presentAutoConnectMigrationIfIdle:
            guard presentation == nil else { return .none }
            presentation = .autoConnectMigrationIntroduction
            return .none

        case .useAutoConnect:
            guard presentation == .autoConnectMigrationIntroduction else { return .none }
            presentation = nil
            return .useAutoConnect

        case let .setUpTailscale(status):
            guard presentation == .autoConnectMigrationIntroduction else { return .none }
            switch status {
            case .pairingRequired:
                presentation = .pairing(.scanner(entry: .autoConnectMigration))
                return .setUpTailscale(requiresPairing: true)
            case .authorized, .loadingAuthorization, .notSelected:
                // Selecting Tailscale while authorization is still being
                // resolved must not open a scanner based on a stale false
                // authorization flag. The shell will promote the setup banner
                // if the authoritative result later requires pairing.
                presentation = nil
                return .setUpTailscale(requiresPairing: false)
            }

        case .presentSettings:
            guard presentation == nil else { return .none }
            presentation = .settings
            return .none

        case let .dismissSettings(presentAutoConnectMigration):
            guard presentation == .settings else {
                return .none
            }
            presentation = presentAutoConnectMigration
                ? .autoConnectMigrationIntroduction
                : nil
            return .none

        case .presentComputers:
            guard presentation == nil else { return .none }
            presentation = .computers
            return .none

        case .dismissComputers:
            guard presentation == .computers else { return .none }
            presentation = nil
            return .retryAutoConnectMigration

        case let .presentPairing(pairingPresentation):
            switch presentation {
            case let .child(child), let .dismissingChild(child, _):
                presentation = .dismissingChild(
                    child,
                    pendingPairing: pairingPresentation
                )
            default:
                presentation = .pairing(pairingPresentation)
            }
            return .none

        case let .presentChild(child):
            guard presentation == nil else { return .none }
            presentation = .child(child)
            return .none

        case let .dismissChild(child):
            guard presentation == .child(child) else { return .none }
            presentation = .dismissingChild(child, pendingPairing: nil)
            return .none

        case let .childDidDismiss(child):
            switch presentation {
            case let .child(activeChild) where activeChild == child:
                presentation = nil
                return .retryAutoConnectMigration
            case let .dismissingChild(activeChild, pendingPairing)
                where activeChild == child:
                if let pendingPairing {
                    presentation = .pairing(pendingPairing)
                    return .none
                }
                presentation = nil
                return .retryAutoConnectMigration
            default:
                return .none
            }

        case let .authenticationChanged(isAuthenticated):
            guard !isAuthenticated else { return .none }
            let effect: Effect
            switch presentation {
            case .pairing, .dismissingChild(_, pendingPairing: .some):
                effect = .finishPairing
            default:
                effect = .none
            }
            presentation = nil
            return effect

        case let .migrationEligibilityChanged(isEligible):
            guard !isEligible,
                  presentation == .autoConnectMigrationIntroduction else {
                return .none
            }
            presentation = nil
            return .none

        case .sheetDidRequestDismissal:
            switch presentation {
            case .autoConnectMigrationIntroduction:
                presentation = nil
                return .acknowledgeAutoConnectMigration
            case .pairing:
                presentation = nil
                return .finishPairing
            case .settings, .computers:
                presentation = nil
                return .none
            case .child, .dismissingChild, nil:
                return .none
            }

        case .dismissPairing:
            guard case .pairing = presentation else { return .none }
            presentation = nil
            return .finishPairing
        }
    }
}
