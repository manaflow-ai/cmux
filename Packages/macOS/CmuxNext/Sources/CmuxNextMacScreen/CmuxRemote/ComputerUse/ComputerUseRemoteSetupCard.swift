public import CmuxNextDesign
import Foundation

/// Computer Use setup's card when Computer Use runs in cmux Remote: it names the two macOS
/// permissions cmux Remote needs, as macOS 27 titles them (Accessibility's prompt is "Device
/// Control and Data Access" there, which people do not recognise), with the older names in
/// brackets, then follows each request. It is an approval-style card: top right, over every app,
/// never activating, and only the person's press answers it (`DebugDialog.userOnly`).
public nonisolated enum ComputerUseRemoteSetupCard: String, Sendable, Equatable {
    /// Both permissions named; Not Now or Continue.
    case ask
    /// Step 1: Accessibility was requested.
    case accessibility
    /// Step 2: Screen Recording was requested.
    case screenRecording

    public static let continueButton = "continue"
    public static let notNowButton = "notNow"
    public static let openSettingsButton = "openSettings"
    public static let closeButton = "close"
}

/// Shows and closes the setup card (``ComputerUseApprovalCards``; tests record it).
@MainActor
public protocol ComputerUseRemoteSetupPresenting: AnyObject {
    /// Shows `card` (replacing the one shown); `answered` gets the pressed button's id, never a dismissal.
    func showSetup(_ card: ComputerUseRemoteSetupCard, answered: @escaping @MainActor (String) -> Void)
    /// Closes the card, if one shows.
    func withdrawSetup()
}

extension ComputerUseApprovalCards: ComputerUseRemoteSetupPresenting {
    static let setupCardID = "computer-use-remote-setup"

    public func showSetup(_ card: ComputerUseRemoteSetupCard, answered: @escaping @MainActor (String) -> Void) {
        guard setupCard != card || dialogID(Self.setupCardID) == nil else { return }
        withdrawSetup()
        setupCard = card
        placeCard(Self.setupCardID, spec: Self.setupSpec(card)) { [weak self] button in
            self?.setupCard = nil
            answered(button)
        }
    }

    public func withdrawSetup() {
        setupCard = nil
        withdraw(Self.setupCardID)
    }

    /// The card's dialog for `card`.
    public static func setupSpec(_ card: ComputerUseRemoteSetupCard) -> CmuxDialogSpec {
        let strings = ComputerUseRemoteSetupStrings.self
        switch card {
        case .ask:
            return CmuxDialogSpec(title: strings.askTitle, lines: strings.askLines,
                                  buttons: [CmuxDialogButton(id: ComputerUseRemoteSetupCard.notNowButton, title: strings.notNow, role: .cancel),
                                            CmuxDialogButton(id: ComputerUseRemoteSetupCard.continueButton, title: strings.proceed, role: .default)],
                                  identifier: ComputerUseApprovalService.remoteSetupDialogIdentifier)
        case .accessibility, .screenRecording:
            let screen = card == .screenRecording
            return CmuxDialogSpec(title: strings.stepTitle(screenRecording: screen), lines: strings.stepLines(screenRecording: screen),
                                  buttons: [CmuxDialogButton(id: ComputerUseRemoteSetupCard.closeButton, title: strings.close, role: .cancel),
                                            CmuxDialogButton(id: ComputerUseRemoteSetupCard.openSettingsButton, title: strings.openSettings, role: .normal)],
                                  identifier: ComputerUseApprovalService.remoteSetupDialogIdentifier)
        }
    }
}

/// The setup card's words (`CmuxRemote` table).
enum ComputerUseRemoteSetupStrings {
    /// macOS 27's names, with the older names in brackets.
    static var accessibilityName: String {
        String(localized: "computerUse.remoteSetup.accessibilityName", defaultValue: "Device Control and Data Access (Accessibility)",
               table: "CmuxRemote", bundle: .module)
    }
    static var screenRecordingName: String {
        String(localized: "computerUse.remoteSetup.screenRecordingName", defaultValue: "Screen & System Audio Recording (Screen Recording)",
               table: "CmuxRemote", bundle: .module)
    }

    static var askTitle: String {
        String(localized: "computerUse.remoteSetup.askTitle", defaultValue: "Allow cmux Remote to Use This Mac", table: "CmuxRemote", bundle: .module)
    }
    static var askLines: [String] {
        [String(localized: "computerUse.remoteSetup.askIntro",
                defaultValue: "Computer Use runs in cmux Remote. macOS needs two permissions for cmux Remote. Continue asks for each in turn.",
                table: "CmuxRemote", bundle: .module),
         String(format: String(localized: "computerUse.remoteSetup.askAccessibility", defaultValue: "1. %@, so agents can click and type in apps.",
                               table: "CmuxRemote", bundle: .module), accessibilityName),
         String(format: String(localized: "computerUse.remoteSetup.askScreenRecording", defaultValue: "2. %@, so agents can see the windows they work in.",
                               table: "CmuxRemote", bundle: .module), screenRecordingName)]
    }

    static func stepTitle(screenRecording: Bool) -> String {
        String(format: String(localized: "computerUse.remoteSetup.stepTitle", defaultValue: "Allow cmux Remote: %@", table: "CmuxRemote", bundle: .module),
               screenRecording ? screenRecordingName : accessibilityName)
    }

    /// One line: what to do now. On macOS 27 the Accessibility prompt is titled "Device Control and Data Access".
    static func stepLines(screenRecording: Bool) -> [String] {
        screenRecording
            ? [String(format: String(localized: "computerUse.remoteSetup.stepScreenRecording",
                                     defaultValue: "Step 2 of 2. In System Settings, turn on cmux Remote under %@. If macOS offers Quit & Reopen, choose it: cmux and your agents keep running.",
                                     table: "CmuxRemote", bundle: .module), screenRecordingName)]
            : [String(format: String(localized: "computerUse.remoteSetup.stepAccessibility",
                                     defaultValue: "Step 1 of 2. When macOS asks for %@, open System Settings and turn on cmux Remote. This card closes by itself once it is on.",
                                     table: "CmuxRemote", bundle: .module), accessibilityName)]
    }

    static var proceed: String { String(localized: "computerUse.remoteSetup.continue", defaultValue: "Continue", table: "CmuxRemote", bundle: .module) }
    static var notNow: String { String(localized: "computerUse.remoteSetup.notNow", defaultValue: "Not Now", table: "CmuxRemote", bundle: .module) }
    static var close: String { String(localized: "computerUse.remoteSetup.close", defaultValue: "Close", table: "CmuxRemote", bundle: .module) }
    static var openSettings: String {
        String(localized: "computerUse.remoteSetup.openSettings", defaultValue: "Open System Settings", table: "CmuxRemote", bundle: .module)
    }
}
