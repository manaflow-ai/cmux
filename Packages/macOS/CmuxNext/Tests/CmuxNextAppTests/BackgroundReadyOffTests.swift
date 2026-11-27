import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
@testable import CmuxNextQuit
import CmuxNextSettings
import Testing

/// `app.backgroundReady` off (the default; Leo 2026-11-17, ask-b2b0f899c1): nothing a person sees or the app
/// does changes. Every quit ends the process with the origin and choice it had before, no launch starts hidden,
/// no login item is asked for, no Quit Completely is offered and the menu bar menu keeps its rows.
@MainActor
struct BackgroundReadyOffTests {
    private static let origins: [QuitOrigin] = [
        .interactive, .explicit(.keep), .explicit(.endKeepLayout), .explicit(.endEverything), .scripted, .powerOff, .signal,
    ]

    private static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func offNeverStaysHiddenForAnyQuit() {
        let mode = BackgroundReadyRules.mode("off")
        #expect(mode == .off)
        for origin in Self.origins {
            for updateInstalls in [false, true] {
                for completely in [false, true] {
                    #expect(!BackgroundReadyRules.staysHidden(mode, origin: origin, updateInstallsOnQuit: updateInstalls, quitCompletely: completely),
                            "off stayed hidden for \(origin) update=\(updateInstalls) completely=\(completely)")
                }
            }
        }
    }

    @Test func offLaunchesNormallyAndRegistersNoLoginItem() {
        #expect(BackgroundReadyRules.atLaunch(.off, launchedAsLoginItem: false) == .normal)
        #expect(!BackgroundReadyRules.registersLoginItem(.off))
        #expect(!BackgroundReadyRules.registersPrereadAgent(.off))
        #expect(!BackgroundReadyRules.offersQuitCompletely(.off))
        #expect(!BackgroundReadyRules.exitsForUpdate(.off, hidden: false, updateStaged: true))
    }

    /// An unknown value is off, as the setting reads it.
    @Test func anUnknownValueIsOff() {
        #expect(BackgroundReadyRules.mode("sometimes") == .off)
        #expect(BackgroundReadyRules.mode("") == .off)
    }

    /// The App's services with no settings (the default, off): the quit's decision is `QuitPolicy`'s alone, as
    /// before, and the controller hides nothing, defers nothing and offers no Quit Completely.
    @Test func theAppsQuitIsUnchangedWithTheSettingOff() {
        let services = Self.services()
        let controller = services.backgroundReady
        #expect(controller.mode == .off)
        for origin in Self.origins {
            #expect(!controller.staysHidden(after: origin, completely: false), "a quit from \(origin) stayed hidden")
            for behavior in QuitBehavior.allCases {
                #expect(QuitPolicy.decide(origin, behavior: behavior) == QuitRules.decide(origin, remembered: QuitSessionsChoice(rawValue: behavior.rawValue)))
            }
        }
        #expect(!controller.quitBegan(), "a quit with the setting off was Quit Completely")
        #expect(!controller.isHidden)
        #expect(!controller.defersRestore)
        #expect(!controller.chromiumWarmupDeferred)
        #expect(!controller.offersQuitCompletely)
        #expect(!controller.showIfHidden("test"), "a show with nothing hidden did something")
    }

    /// The menu bar menu ends with Quit, as before; Quit Completely follows it only while the setting is on.
    @Test func theMenuBarMenuKeepsQuitLastWithTheSettingOff() {
        let quitRows = { (state: MenuBarMenuState) in
            MenuBarMenuSpec().items(for: state, isBound: { _ in true }).compactMap { item -> String? in
                if case .action(let id, _, _) = item, id.rawValue.hasPrefix("quit") { id.rawValue } else { nil }
            }
        }
        #expect(quitRows(MenuBarMenuState()) == ["quit"])
        #expect(quitRows(MenuBarMenuState(quitCompletely: true)) == ["quit", "quitCompletely"])
    }
}
