import AppKit
import CmuxNextHome
import Foundation

/// The card's engine rows (`HomeChiefSettingsView`): reading the brain's engine, writing a pick,
/// and saying why one did not take.
extension HomeChiefSettingsView {
    // MARK: Engine

    /// Re-reads the engine and the last turns (a new message or a turn's
    /// end) off the main actor, then shows them, or why it could not.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let source = source
        let home = muxHome
        // task-owner: one read off the main actor; ends when it is shown
        return Task { [weak self] in
            // The automations come in their own read, so a slow engine read never holds them.
            self?.refreshAutomations()
            // This Mac's acpmux harnesses, for a brain that runs here (a paired server's are its own).
            if let self, source.isLocal { listedHarnesses = await listHarnesses() }
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.read()) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            // A read of the Chief shown before (another conversation) is not shown.
            guard let self, self.source.isLocal == source.isLocal, self.source.place == source.place, muxHome == home else { return }
            switch result {
            case .success(let snapshot): show(snapshot)
            case .failure(let error): say(error, readable: false)
            }
        }
    }

    /// Sets (nil: clears) one engine field on the brain, then shows the result.
    @discardableResult
    public func pick(_ key: String, _ value: String?) -> Task<Void, Never> {
        pick([key: value])
    }

    /// Sets (nil: clears) engine fields on the brain in one write, then shows
    /// the result. A write the brain refuses shows what it still runs again,
    /// so a popup never keeps a value the brain did not take.
    @discardableResult
    func pick(_ fields: [String: String?]) -> Task<Void, Never> {
        let source = source
        let home = muxHome
        changeFailed = false
        // task-owner: one write off the main actor; ends when its result is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefSnapshot, HomeChiefEngineError> in
                do { return .success(try await source.set(fields)) } catch let error as HomeChiefEngineError { return .failure(error) } catch { return .failure(.other(String(describing: error))) }
            }.value
            // A pick for the Chief shown before (another conversation, or its other host) is not shown.
            guard let self, muxHome == home, self.source.isLocal == source.isLocal, self.source.place == source.place else { return }
            switch result {
            case .success(let snapshot):
                if case let picked?? = fields["model"], let harness = snapshot.harness ?? snapshot.effective?.harness {
                    recents.remember(picked, harness: harness)
                }
                show(snapshot)
                onEngineChanged()
            case .failure(let error):
                if let shownEngine { show(shownEngine) }
                say(error, readable: true)
            }
        }
    }

    /// Says `error`; the pickers stay usable only when the brain answered before. A pick's error
    /// (`readable`: the brain answered, then refused) stays until the next change.
    func say(_ error: HomeChiefEngineError, readable: Bool) {
        if !readable { for button in pickers { button.isEnabled = false } }
        note(error.text, kept: readable)
    }

    /// Shows `text` in the note and has VoiceOver say it once (a refresh that says the same again,
    /// such as a brain that still does not answer, is not announced again); `kept` keeps it through
    /// refreshes. The card may be closed (a picture's open panel closed it): the announcement then
    /// comes from the main window.
    func note(_ text: String, kept: Bool) {
        let changed = failure.isHidden || failure.stringValue != text
        failure.stringValue = text
        failure.isHidden = false
        // The avatar's tooltip opens below it, over this note: it steps aside while the note shows.
        avatarButton.themedToolTip = nil
        changeFailed = kept
        if changed {
            var element: Any = NSApp as Any
            if failure.window?.isVisible == true { element = failure } else if let main = NSApp.mainWindow { element = main }
            NSAccessibility.post(element: element, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        onResize()
    }

    /// The card closed: a note about a change is said and seen, so the next open starts clear. A
    /// picture's note, set after its open panel closed the card, waits for the next open.
    func cardClosed() {
        guard changeFailed else { return }
        hideNote(resize: false)
    }

    /// Hides the note; the avatar's tooltip comes back.
    func hideNote(resize: Bool = true) {
        changeFailed = false
        failure.isHidden = true
        avatarButton.themedToolTip = HomeEngineStrings.changePicture
        if resize { onResize() }
    }

    func show(_ snapshot: HomeChiefSnapshot) {
        shownEngine = snapshot
        if !changeFailed, !failure.isHidden { hideNote(resize: false) }
        // A harness check under way keeps the pickers off until it answers.
        for button in pickers { button.isEnabled = checkingHarness == nil }
        let shown = titles(snapshot)
        fill(harness, shown.harnesses, current: snapshot.harness, defaultTitle: shown.defaultHarness, title: ChiefBackend.title(for:))
        showHarnessHint()
        fill(model, shown.menu, current: snapshot.model, defaultTitle: shown.defaultModel)
        fill(effort, shown.efforts, current: snapshot.effort, defaultTitle: shown.defaultEffort)
        fill(speed, [("fast", HomeEngineStrings.speedFast)], current: snapshot.speed == "default" ? nil : snapshot.speed,
             defaultTitle: HomeEngineStrings.defaultValue)
        if let row = speed.superview, row.isHidden == shown.offersFast { row.isHidden = !shown.offersFast }
        reactionRows.show(snapshot)
        stats.stringValue = snapshot.turns.first.map(HomeEngineStrings.lastTurn) ?? HomeEngineStrings.noTurn
        // Which engine answered each recent reply (the trace's turn.end).
        replies.stringValue = snapshot.turns.isEmpty ? ""
            : HomeEngineStrings.answeredBy + "\n" + snapshot.turns.map(HomeEngineStrings.reply).joined(separator: "\n")
        replies.isHidden = snapshot.turns.isEmpty
        // A hosted cloud Chief whose brain is off answers no message: say so, never a silent Chief.
        if snapshot.brainOff, !changeFailed {
            note(HomeEngineStrings.hostedBrainOff, kept: false)
        } else {
            onResize()
        }
    }

    /// `values` (value, title) after a "Default" item that names what it runs,
    /// and the current value kept even when it is not one of them (titled by `title`).
    func fill(_ button: NSPopUpButton, _ values: [(value: String, title: String)], current: String?, defaultTitle: String,
              title: (String) -> String = { $0 }) {
        button.removeAllItems()
        button.addItem(withTitle: defaultTitle)
        button.lastItem?.representedObject = nil
        var all = values
        if let current, !all.contains(where: { $0.value == current }) { all.append((current, title(current))) }
        for item in all {
            // Added as items, not by title: two ids can read as one name, and addItem(withTitle:) keeps only one.
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            entry.representedObject = item.value
            // A value shown by a name keeps its id where a person can still find it.
            entry.toolTip = item.title == item.value ? nil : item.value
            button.menu?.addItem(entry)
        }
        if let current, let index = all.firstIndex(where: { $0.value == current }) {
            button.selectItem(at: index + 1)
        } else {
            button.selectItem(at: 0)
        }
    }

    /// The Model popup: Default, then ``HomeChiefModelMenu``'s sections (a header is a section
    /// header item, not a pick). The chosen model is selected in its own section, not in Recent.
    func fill(_ button: NSPopUpButton, _ menu: HomeChiefModelMenu, current: String?, defaultTitle: String) {
        button.removeAllItems()
        button.addItem(withTitle: defaultTitle)
        button.lastItem?.representedObject = nil
        var selected = 0
        var recent = false
        for entry in menu.entries {
            switch entry {
            case .header(let title):
                recent = title == HomeEngineStrings.recentSection
                button.menu?.addItem(.sectionHeader(title: title))
            case .model(let entry):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.representedObject = entry.value
                item.toolTip = entry.detail
                button.menu?.addItem(item)
                if !recent, selected == 0, entry.value == current { selected = button.numberOfItems - 1 }
            }
        }
        button.selectItem(at: selected)
    }

    /// The pickers, in the card's order.
    var pickers: [NSPopUpButton] { [harness, model, effort, speed] }

    /// The rows' items for `snapshot`, with this harness's recent models.
    func titles(_ snapshot: HomeChiefSnapshot) -> HomeChiefEngineTitles {
        let harness = snapshot.harness ?? snapshot.effective?.harness
        return HomeChiefEngineTitles(snapshot, recents: harness.map(recents.models(harness:)) ?? [], listed: listedHarnesses)
    }

    @objc func picked(_ sender: NSPopUpButton) {
        let value = sender.selectedItem?.representedObject as? String
        switch sender {
        case harness: pickHarness(value)
        case model: pickModel(value)
        case speed: pick("speed", value)
        default: pick("effort", value)
        }
    }

    /// Sets the model `value` (nil: Default). A chosen effort the new model does not take, or
    /// Fast on a model that has none, is cleared in the same write, so the next turn never
    /// starts on a level the model refuses.
    @discardableResult
    func pickModel(_ value: String?) -> Task<Void, Never> {
        var fields: [String: String?] = ["model": value]
        guard var next = shownEngine else { return pick(fields) }
        next.model = value
        let after = HomeChiefEngineTitles(next)
        if let effort = next.effort, !after.efforts.contains(where: { $0.value == effort }) { fields["effort"] = .some(nil) }
        if next.speed == "fast", !after.offersFast || HomeChiefModelMenu.release(of: value ?? "", in: next.models)?.fast == false {
            fields["speed"] = .some(nil)
        }
        return pick(fields)
    }

    /// Sets the harness `value` (nil: Default). A new harness starts on its own default model and
    /// effort, as the Chief editor's backend picker does: the brain keeps a field it is not sent,
    /// and another harness's model would not run on this one. On this Mac's brain a new harness
    /// first passes its backend check (`checkHarness`, one real hello turn), as the editor
    /// requires; one that fails is not set, and the note says so. Only the official engines are
    /// checked: the check runs on the app's acpmux, and a route the Chief's own acpmux config adds
    /// (`claude-cr`) is not there. While the check runs the pickers stay off and the note says so;
    /// a newer pick or another Chief drops its answer.
    @discardableResult
    func pickHarness(_ value: String?) -> Task<Void, Never> {
        showHarnessHint()
        if Self.keepsHarness(value, shown: shownEngine) { return pick("harness", value) }
        let fields: [String: String?] = ["harness": value, "model": nil, "effort": nil, "speed": nil]
        guard let value, source.isLocal, ChiefBackend(id: value) != nil else { checkingHarness = nil; return pick(fields) }
        let home = muxHome
        let title = ChiefBackend.title(for: value)
        checkingHarness = value
        for button in pickers { button.isEnabled = false }
        note(String(format: HomeEngineStrings.harnessCheckingFormat, title), kept: true)
        // task-owner: the check, then one write; ends when its result is shown
        return Task { [weak self] in
            guard let self else { return }
            let passed = await checkHarness(value)
            guard checkingHarness == value, muxHome == home, source.isLocal else { return }
            checkingHarness = nil
            guard passed else {
                if let shownEngine { show(shownEngine) }
                note(String(format: HomeEngineStrings.harnessCheckFailedFormat, title), kept: true)
                return
            }
            await pick(fields).value
        }
    }

    /// Whether a harness pick keeps the harness the turns run on: the chosen one again, or, while
    /// none is chosen, the harness Default runs picked by name. Default picked while a harness is
    /// chosen counts as a change, since what Default would run is not known then.
    nonisolated static func keepsHarness(_ value: String?, shown: HomeChiefSnapshot?) -> Bool {
        guard let shown else { return false }
        if shown.harness == value { return true }
        // What Default runs is known only while no harness is chosen.
        guard shown.harness == nil, let runs = shown.effective?.harness else { return false }
        return value == runs
    }

    /// The hint under the Harness row: only UniiChat's (sign in with `unii login` first), since
    /// the other engines' sign-in is the brain host's own (a cloud Chief's runs on its server).
    func showHarnessHint() {
        guard source.choosesHarness else { return }
        let unii = harness.selectedItem?.representedObject as? String == ChiefBackend.unii.id
        let hint = unii ? ChiefBackend.unii.hint : nil
        harnessHint.stringValue = hint ?? ""
        let changed = harnessHint.isHidden != (hint == nil)
        harnessHint.isHidden = hint == nil
        if changed { onResize() }
    }
}
