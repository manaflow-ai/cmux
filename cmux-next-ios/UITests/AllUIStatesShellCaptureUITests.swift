import XCTest

/// All-UI-states capture, part 1: launch, onboarding and sign-in, setup and
/// pairing, the shell (tab bar, team sidebar, toasts, banners, app lock) and
/// every Settings page. See `UIStateCapture.swift`.
final class AllUIStatesShellCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let signedOut = ["CMUX_MOBILE_MOCK_AUTH": "1", "CMUX_MOBILE_CLEAR_AUTH": "1"]

    @MainActor
    func testOnboardingAndSignIn() {
        let g = "1 Onboarding, sign-in and pairing"
        capture([
            Scene(group: g, id: "launch-mark", env: Self.signedOut, signedIn: false, settle: 0,
                  frames: [("launch-mark", 0.15), ("welcome-intro", 1.2)]),
            Scene(group: g, id: "welcome-settled", env: Self.signedOut, signedIn: false, settle: 6),
            Scene(group: g, id: "welcome-intro-frozen", args: ["-cmux-mobile-intro-freeze", "0.6"], env: Self.signedOut, signedIn: false, settle: 3),
            Scene(group: g, id: "email-sheet", env: Self.signedOut, signedIn: false, settle: 5) { app in
                C.tap(C.label(app, contains: "Continue with email"), "Continue with email")
            },
            Scene(group: g, id: "email-sheet-keyboard", env: Self.signedOut, signedIn: false, settle: 5) { app in
                C.steps([
                    { C.tap(C.label(app, contains: "Continue with email"), "Continue with email") },
                    { C.showKeyboard(app, field: app.textFields.firstMatch, "email field") },
                    { app.typeText("someone@example.com"); return nil },
                ])
            },
            Scene(group: g, id: "email-code", args: ["-cmux-mobile-email", "someone@example.com", "-cmux-mobile-no-restore"],
                  env: Self.signedOut, signedIn: false, settle: 4) { app in
                C.wait(app.textFields["Code"].firstMatch, "code field")
            },
            Scene(group: g, id: "email-code-wrong", args: ["-cmux-mobile-email", "someone@example.com", "-cmux-mobile-no-restore"],
                  env: Self.signedOut, signedIn: false, settle: 4) { app in
                let tip = app.buttons["Continue"].firstMatch
                if tip.waitForExistence(timeout: 2) { tip.tap() }
                return C.steps([
                    { C.showKeyboard(app, field: app.textFields["Code"].firstMatch, "code field") },
                    { app.typeText("111111"); return nil },
                ])
            },
            Scene(group: g, id: "onboarding-demo", args: ["-cmux-mobile-demo", "onboarding"], env: Self.signedOut, signedIn: false, settle: 0,
                  frames: [("onboarding-welcome", 1.5), ("onboarding-email", 3.5), ("onboarding-code", 6.5),
                           ("onboarding-team", 10), ("onboarding-notifications", 14), ("onboarding-shell", 19)]),
            Scene(group: g, id: "setup-teams-loading", args: ["-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "NO"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1", "CMUX_MOBILE_MOCK_TEAMS_DELAY": "60"], signedIn: false, settle: 3),
            Scene(group: g, id: "setup-teams-choose", args: ["-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "NO"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1"], signedIn: false, settle: 3) { app in
                C.wait(app.scrollViews["setup.teams.choose"], "team chooser")
            },
            Scene(group: g, id: "setup-create-team", args: ["-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "NO"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1"], signedIn: false, settle: 3) { app in
                C.tap(C.any(app, "setup.teams.create"), "Create team row")
            },
            Scene(group: g, id: "setup-signout-confirm", args: ["-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "NO"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1"], signedIn: false, settle: 3) { app in
                C.tap(C.any(app, "setup.sign-out"), "setup sign-out")
            },
            Scene(group: g, id: "setup-pair-waiting", args: ["-cmux-mobile-setup-pair"], env: ["CMUX_MOBILE_MOCK_AUTH": "1"],
                  signedIn: false, settle: 0, frames: [("setup-pair-waiting", 2.6), ("setup-pair-mac-found", 7.5)]),
            Scene(group: g, id: "setup-pair-elsewhere", args: ["-cmux-mobile-setup-pair", "-cmux-mobile-setup-pair-elsewhere"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1"], signedIn: false, settle: 7),
            Scene(group: g, id: "setup-pair-no-account-mac", args: ["-cmux-mobile-setup-pair", "-cmux-mobile-setup-pair-other-account"],
                  env: ["CMUX_MOBILE_MOCK_AUTH": "1"], signedIn: false, settle: 4),
            Scene(group: g, id: "setup-notifications", args: ["-cmux-mobile-setup-pair"], env: ["CMUX_MOBILE_MOCK_AUTH": "1"],
                  signedIn: false, settle: 7) { app in
                let next = app.buttons["setup.pair-mac.cta"].firstMatch
                return C.tap(next, "Connect your Mac continue")
            },
            Scene(group: g, id: "notification-permission-alert", args: ["-cmux-mobile-setup-pair"], env: ["CMUX_MOBILE_MOCK_AUTH": "1"],
                  signedIn: false, looks: [.light], settle: 7) { app in
                C.steps([
                    { C.tap(app.buttons["setup.pair-mac.cta"].firstMatch, "Connect your Mac continue") },
                    { C.tap(C.label(app, contains: "Allow"), "Allow notifications button") },
                    { C.wait(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch, "system permission alert", timeout: 8) },
                ])
            },
            Scene(group: g, id: "machine-invite-sheet", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "https://cmux.com/pair?i=abcde-i2345"]) { app in
                C.wait(app.staticTexts["machineInvite.code"], "machine invite code")
            },
            Scene(group: g, id: "machine-invite-copied", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "https://cmux.com/pair?i=abcde-i2345"]) { app in
                C.tap(app.buttons["machineInvite.copyLine"], "copy line")
            },
        ])
    }

    @MainActor
    func testShell() {
        let g = "2 Shell: tab bar, team sidebar, toasts, banners"
        var scenes: [Scene] = [
            Scene(group: g, id: "tab-home", args: ["-cmux-mobile-tab", "home"]),
            Scene(group: g, id: "tab-workspaces", args: ["-cmux-mobile-tab", "workspaces"]),
            Scene(group: g, id: "tab-feed", args: ["-cmux-mobile-tab", "feed"]),
            Scene(group: g, id: "tab-settings", args: ["-cmux-mobile-tab", "settings"]),
            Scene(group: g, id: "sidebar-open", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]),
            Scene(group: g, id: "sidebar-transparent-teams", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open", "-cmux-mobile-team-transparent"]),
            Scene(group: g, id: "sidebar-add-team-menu", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]) { app in
                C.tap(app.buttons["Add team"].firstMatch, "Add team")
            },
            Scene(group: g, id: "alert-create-team", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]) { app in
                C.steps([
                    { C.tap(app.buttons["Add team"].firstMatch, "Add team") },
                    { C.tap(app.buttons["Create team"].firstMatch, "Create team item") },
                ])
            },
            Scene(group: g, id: "alert-join-team", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]) { app in
                C.steps([
                    { C.tap(app.buttons["Add team"].firstMatch, "Add team") },
                    { C.tap(C.label(app, contains: "Join with invite"), "Join item") },
                ])
            },
            Scene(group: g, id: "sidebar-team-context-menu", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]) { app in
                C.longPress(C.label(app, contains: "Build Fleet"), "Build Fleet team row")
            },
            Scene(group: g, id: "toast-invite-needs-service", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]) { app in
                C.steps([
                    { C.longPress(C.label(app, contains: "Build Fleet"), "Build Fleet team row") },
                    { C.tap(C.label(app, contains: "Invite to team"), "Invite to team") },
                ])
            },
            Scene(group: g, id: "team-appearance-editor", args: ["-cmux-mobile-demo", "editor"], settle: 5),
            Scene(group: g, id: "drawer-demo", args: ["-cmux-mobile-demo", "drawer"], settle: 0,
                  frames: [("drawer-dragging", 1.6), ("drawer-open", 3.0), ("drawer-team-switched", 7.0)]),
            Scene(group: g, id: "rubber-band", args: ["-cmux-mobile-demo", "rubber"], settle: 0,
                  frames: [("sidebar-overdrag", 2.6)]),
            Scene(group: g, id: "states-demo", args: ["-cmux-mobile-demo", "states"], settle: 0,
                  frames: [("workspaces-loading", 3.0), ("workspaces-failed", 5.0), ("workspaces-offline-banner", 8.0),
                           ("macs-asleep", 11.0), ("no-macs-connect", 13.0), ("toast-paired", 16.5)]),
        ]
        for banner in ["connected", "reconnecting", "offline", "pairing", "pairing-reset"] {
            scenes.append(Scene(group: g, id: "banner-\(banner)", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-banner-demo", banner]))
        }
        scenes.append(Scene(group: g, id: "banner-signed-out", args: ["-cmux-mobile-recovery-gallery", "signedout"]))
        scenes.append(Scene(group: g, id: "link-status-demo", args: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-link-status-demo", "YES"]) { app in
            C.tap(C.any(app, "workspaces.filter"), "filter menu")
        })
        capture(scenes)
    }

    @MainActor
    func testSettings() {
        let g = "13 Settings"
        var scenes: [Scene] = [
            Scene(group: g, id: "root-top", args: ["-cmux-mobile-tab", "settings"]),
            Scene(group: g, id: "root-appearance", args: ["-cmux-mobile-demo", "settings-middle"], settle: 4),
            Scene(group: g, id: "root-bottom", args: ["-cmux-mobile-demo", "settings-bottom"], settle: 4),
            Scene(group: g, id: "signout-confirm", args: ["-cmux-mobile-demo", "settings-bottom"], settle: 4) { app in
                C.tap(C.any(app, "settings.logout"), "Sign out row")
            },
            Scene(group: g, id: "compact-list-on", args: ["-cmux-mobile-tab", "settings", "-cmuxMobile.settings.compactWorkspaceList", "YES"]),
        ]
        let pages = ["account", "team", "transport", "devices", "terminal", "terminalSizing", "composer", "notifications",
                     "acknowledgements", "chiefCalls", "screenSharing", "accentColor", "automations", "longPressMenus"]
        for page in pages {
            scenes.append(Scene(group: g, id: "page-\(page)", args: ["-cmux-mobile-settings-page", page], settle: 3.5))
        }
        scenes += [
            Scene(group: g, id: "page-transport-details", args: ["-cmux-mobile-settings-page", "transport", "-cmux-mobile-transport-details", "YES"], settle: 3.5),
            Scene(group: g, id: "devices-remove-this-phone", args: ["-cmux-mobile-settings-page", "devices"], settle: 3.5) { app in
                C.steps([{ C.scrollDown(app, times: 3) }, { C.tap(C.any(app, "settings.removeThisPhone"), "Remove this iPhone") }])
            },
            Scene(group: g, id: "devices-mac-row-menu", args: ["-cmux-mobile-settings-page", "devices"], settle: 3.5) { app in
                C.longPress(C.label(app, contains: "Mac Studio"), "Mac Studio row")
            },
            Scene(group: g, id: "devices-mac-row-swipe", args: ["-cmux-mobile-settings-page", "devices"], settle: 3.5) { app in
                C.swipeLeft(app.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Mac Studio'")).firstMatch, "Mac Studio cell")
            },
            Scene(group: g, id: "devices-pair-scanner", args: ["-cmux-mobile-settings-page", "devices"], settle: 3.5) { app in
                C.steps([{ C.scrollDown(app, times: 1) }, { C.tap(C.any(app, "settings.scanMacCode"), "Scan QR row") }])
            },
            Scene(group: g, id: "chief-calls-key-typed", args: ["-cmux-mobile-settings-page", "chiefCalls"], settle: 3.5) { app in
                C.steps([
                    { C.showKeyboard(app, field: C.any(app, "settings.chiefCalls.keyField"), "key field") },
                    { app.typeText("sk-demo-0000000000000000"); return nil },
                ])
            },
            Scene(group: g, id: "accent-picked", args: ["-cmux-mobile-settings-page", "accentColor"], settle: 3.5) { app in
                let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.accentColor.'"))
                guard cells.count > 2 else { return "no accent choices" }
                cells.element(boundBy: 2).tap()
                return nil
            },
            Scene(group: g, id: "team-editor-from-settings", args: ["-cmux-mobile-settings-page", "team"], settle: 3.5) { app in
                C.tap(C.label(app, contains: "Color and icon"), "Color and icon row")
            },
            Scene(group: g, id: "dynamic-type-xxxl", args: ["-cmux-mobile-tab", "settings", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        capture(scenes)
    }
}
