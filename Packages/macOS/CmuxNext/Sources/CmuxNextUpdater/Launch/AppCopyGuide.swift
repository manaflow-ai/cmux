public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import CmuxNextWakeups
import os
import Security

/// What the running copy tells the person about other copies of itself (Leo, 2026-11-08, on the setup flows: "HARD
/// crit the setup flows"):
/// - a second copy opened (a newer download, a "cmux NIGHTLY 2", the disk image's copy) hands off to this one; this
///   copy says which copy and version kept running and which was opened, and offers to switch when the opened one is
///   newer (``SecondCopyNotice``); the URLs that copy could not hand on open here (``SecondCopyNote``);
/// - this copy runs translocated or from a disk image; at launch it offers to move itself to Applications and reopen
///   from there (``AppMoveOffer``).
@MainActor public final class AppCopyGuide {
    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")

    private let open: @MainActor ([URL]) -> Void
    /// Records the quit before a switch or move as one that keeps every session (the updater's relaunch hook).
    private let relaunching: @MainActor () -> Void
    private let center: CmuxDialogCenter
    /// A second-copy dialog is up: further notes open their URLs but ask nothing more.
    private var asking = false

    /// `open` routes URLs as the app's own open events do; `relaunching` runs right before this copy quits for a
    /// switch or a move, so the quit keeps every session whatever `app.quitBehavior` says.
    public init(open: @escaping @MainActor ([URL]) -> Void, relaunching: @escaping @MainActor () -> Void,
                center: CmuxDialogCenter = .shared) {
        self.open = open
        self.relaunching = relaunching
        self.center = center
    }

    /// Starts listening for second copies and checks where this copy runs. Only a guarded launch (a release build,
    /// not DEV or a second-instance opt-out) takes part, and only the person's own (`activates` false for an agent
    /// launch, which never asks anything).
    public func start(activates: Bool) {
        guard activates, SingleInstanceGuard.current.isGuarded, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        register(bundleIdentifier: bundleIdentifier)
        offerMoveIfPassing()
    }

    // MARK: Second copies

    func received(_ note: SecondCopyNote) {
        if !note.urls.isEmpty {
            NSApp.activate()
            open(note.urls)
        }
        guard !asking else { return }
        asking = true
        let this = Self.thisCopy
        // task-owner: one dialog for one note; it ends with the person's answer.
        Task {
            defer { asking = false }
            let notice = await Task.detached(priority: .userInitiated) { () -> SecondCopyNotice in
                var running = this
                running.exists = FileManager.checked.fileExists(atPath: running.path)
                let opened = AppCopy.read(path: note.openedPath)
                // Only a copy of this app is named, and only one signed by this app's team is offered.
                guard opened.bundleIdentifier == running.bundleIdentifier else { return .none }
                let notice = SecondCopyNotice.decide(running: running, opened: opened)
                guard case .tell(_, _, true) = notice else { return notice }
                return .tell(running: running, opened: opened, offersSwitch: Self.signedByThisTeam(opened.path))
            }.value
            guard case .tell(let running, let opened, let offersSwitch) = notice else { return }
            Self.logger.notice("launch: a second copy was opened; telling the person (switch offered: \(offersSwitch, privacy: .public))")
            let answer = await center.present(Self.spec(running: running, opened: opened, offersSwitch: offersSwitch), in: .app)
            guard answer.button == "switch" else { return }
            // The bundle at that path is checked again now: it may have been swapped while the dialog was up.
            let stillSigned = await Task.detached(priority: .userInitiated) { Self.signedByThisTeam(opened.path) }.value
            guard stillSigned else { return }
            reopen(Self.reopenCommand(app: opened.path, ejecting: nil))
        }
    }

    static func spec(running: AppCopy, opened: AppCopy, offersSwitch: Bool) -> CmuxDialogSpec {
        var lines = [running.exists
            ? UpdaterStrings.secondCopyRunning(display(running.path), running.versionText ?? UpdaterStrings.unknownVersion)
            : UpdaterStrings.secondCopyRunningGone(running.versionText ?? UpdaterStrings.unknownVersion, display(running.path)),
            UpdaterStrings.secondCopyOpened(display(opened.path), opened.versionText ?? UpdaterStrings.unknownVersion),
            UpdaterStrings.secondCopyOneAtATime]
        if offersSwitch { lines.append(UpdaterStrings.secondCopySwitchLine) }
        let buttons: [CmuxDialogButton] = offersSwitch
            ? [.cancel(UpdaterStrings.secondCopyKeep), CmuxDialogButton(id: "switch", title: UpdaterStrings.secondCopySwitch, role: .default)]
            : [.ok()]
        return CmuxDialogSpec(title: UpdaterStrings.secondCopyTitle, lines: lines, buttons: buttons, identifier: "cmux.second-copy")
    }

    // MARK: Moving to Applications

    private func offerMoveIfPassing() {
        let running = Self.thisCopy, bundle = Bundle.main.bundleURL
        // task-owner: one launch check and at most one dialog; it ends with the person's answer.
        Task {
            let found = await Task.detached(priority: .utility) { () -> (place: AppCopyPlace, offer: AppMoveOffer)? in
                let place = AppCopyPlace.of(bundlePath: bundle.path)
                guard place.isPassing else { return nil }
                let destination = (AppMoveOffer.applicationsFolder() as NSString).appendingPathComponent(bundle.lastPathComponent)
                let installed = FileManager.checked.fileExists(atPath: destination) ? AppCopy.read(path: destination) : nil
                return AppMoveOffer.decide(running: running, place: place, destination: destination, installed: installed).map { (place, $0) }
            }.value
            guard let found else { return }
            Self.logger.notice("launch: this copy runs from a passing place (\(String(describing: found.place), privacy: .public)); offering a move")
            let answer = await center.present(Self.spec(place: found.place, offer: found.offer), in: .app)
            guard answer.button == "move" else { return }
            let moved = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                Result { try found.offer.perform(running: bundle).path }
            }.value
            switch moved {
            case .success(let app):
                if case .readOnlyVolume(let volume) = found.place {
                    reopen(Self.reopenCommand(app: app, ejecting: volume))
                } else {
                    reopen(Self.reopenCommand(app: app, ejecting: nil))
                }
            case .failure(let error):
                Self.logger.error("launch: the move to Applications failed: \(String(describing: error), privacy: .public)")
                _ = await center.present(CmuxDialogSpec(title: UpdaterStrings.moveFailedTitle, lines: [error.localizedDescription],
                                                        buttons: [.ok()], identifier: "cmux.move-to-applications.failed"), in: .app)
            }
        }
    }

    static func spec(place: AppCopyPlace, offer: AppMoveOffer) -> CmuxDialogSpec {
        var lines = [place == .translocated ? UpdaterStrings.moveTranslocated : UpdaterStrings.moveDiskImage]
        let folder = display((offer.destination as NSString).deletingLastPathComponent)
        let button: String
        switch offer {
        case .move:
            lines.append(UpdaterStrings.moveCopies(folder))
            button = UpdaterStrings.moveButton
        case .replace(_, let installed):
            lines.append(UpdaterStrings.moveReplaces(installed.versionText ?? UpdaterStrings.unknownVersion, folder))
            button = UpdaterStrings.moveReplaceButton
        case .openInstalled(let installed):
            lines.append(UpdaterStrings.moveOpensInstalled(installed.versionText ?? UpdaterStrings.unknownVersion, folder))
            button = UpdaterStrings.moveOpenInstalledButton
        }
        if case .readOnlyVolume = place { lines.append(UpdaterStrings.moveEjects) }
        return CmuxDialogSpec(title: UpdaterStrings.moveTitle, lines: lines,
                              buttons: [.cancel(UpdaterStrings.moveNotNow), CmuxDialogButton(id: "move", title: button, role: .default)],
                              identifier: "cmux.move-to-applications")
    }

    // MARK: Reopening

    static func reopenCommand(app: String, ejecting volume: String?) -> [String] {
        AppMoveOffer.reopenCommand(pid: ProcessInfo.processInfo.processIdentifier, app: app, ejecting: volume)
    }

    /// Whether the bundle at `path` is signed by this running copy's team, read from the running code itself (its
    /// bundle on disk may be gone); false when either has no team.
    nonisolated static func signedByThisTeam(_ path: String) -> Bool {
        var me: SecCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return UpdateDropBack.signingTeam(of: URL(filePath: path, directoryHint: .isDirectory)) == team
    }

    /// Starts the helper that reopens the other copy once this process exits, then quits through the app's own quit,
    /// recorded as one that keeps every session.
    private func reopen(_ command: [String]) {
        let helper = Process()
        helper.executableURL = URL(filePath: command[0])
        helper.arguments = Array(command.dropFirst())
        // task-owner: one spawn, then the quit; ends with the app.
        Task {
            do { try await ProcessLauncher(label: "com.cmuxterm.next.reopen-copy", priority: .userBlocking).launched(helper) } catch {
                Self.logger.error("launch: the reopen helper did not start: \(String(describing: error), privacy: .public)")
                return
            }
            self.relaunching()
            NSApplication.terminateFromRunLoop()
        }
    }

    /// This running copy, from the Info.plist it was launched with (its bundle on disk may be gone or replaced).
    static var thisCopy: AppCopy {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppCopy(path: Bundle.main.bundlePath, bundleIdentifier: info["CFBundleIdentifier"] as? String,
                       version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
    }

    /// `path` with the home folder as `~`.
    static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    // MARK: The distributed notification

    /// The bundle id the registration filters on; nil before ``start(activates:)`` registered.
    private var observedObject: CFString?

    /// One Core Foundation registration with `.deliverImmediately`, as `KeyboardLayoutObserver`: the note arrives
    /// while this copy is in the background, which is when a second copy is opened. The observer is this object;
    /// `deinit` removes it.
    private func register(bundleIdentifier: String) {
        guard observedObject == nil else { return }
        let object = bundleIdentifier as CFString
        observedObject = object
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        secondCopyNoteArrived, SecondCopyNote.name as CFString, SecondCopyNote.pointer(object),
                                        .deliverImmediately)
    }

    nonisolated deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}

/// The Core Foundation callback (any thread): the note is read here and handled on main by the guide that registered.
nonisolated private func secondCopyNoteArrived(_ center: CFNotificationCenter?, _ observer: UnsafeMutableRawPointer?,
                                               _ name: CFNotificationName?, _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?) {
    guard let observer, let note = SecondCopyNote(userInfo: userInfo as? [AnyHashable: Any]) else { return }
    let guide = Unmanaged<AppCopyGuide>.fromOpaque(observer).takeUnretainedValue()
    MainDelivery().run { guide.received(note) }
}
