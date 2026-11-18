import XCTest

extension XCUIApplication {
    /// Mock data's first run, the way a person passes it: "Here's how cmux works" → Continue,
    /// "Choose a space" → `team` (or `pick`), "Start your first agent" → Skip for now. Returns at
    /// once when setup is already done (no setup page within `appearTimeout`).
    @MainActor
    func passFirstRunSetup(team: String = "Manaflow", appearTimeout: TimeInterval = 10,
                           pick: ((XCUIApplication) -> Void)? = nil) {
        let intro = buttons["setup.intro.continue"]
        let choose = scrollViews["setup.teams.choose"]
        let skip = buttons["setup.first-chat.skip"]
        guard intro.waitForExistence(timeout: appearTimeout) || choose.exists || skip.exists else { return }
        if intro.exists { intro.tap() }
        if choose.waitForExistence(timeout: 10) {
            if let pick { pick(self) } else { buttons[team].firstMatch.tap() }
        }
        if skip.waitForExistence(timeout: 10) { skip.tap() }
    }

    /// One poll of ``passFirstRunSetup``'s pages, for a wait that taps whichever shows.
    @MainActor
    func tapFirstRunSetupPage(team: String = "Manaflow") {
        let intro = buttons["setup.intro.continue"]
        let team = buttons[team].firstMatch
        let skip = buttons["setup.first-chat.skip"]
        if intro.exists, intro.isHittable { intro.tap() }
        else if scrollViews["setup.teams.choose"].exists, team.exists, team.isHittable { team.tap() }
        else if skip.exists, skip.isHittable { skip.tap() }
    }
}
