import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// Tells the person, quietly and app-wide, when a file or a layer changes their customization
/// (Leo 2026-11-19: "cmux for themes customizations and whatnot if there's errant files etc that
/// affect customizations it should be able to automatically tell the user and inform them").
///
/// At launch and after each settings load it runs `cmux --json customize doctor --announce`
/// through the bundled CLI, with the environment Settings' library card uses
/// (`SettingsCustomizeLibrary.environment`). The CLI finds everything and marks what it
/// announced seen, so `announce` is non-null only for findings that are new: this type keeps no
/// memory of its own, and only shows that line as a toast whose Review button opens Settings at
/// the doctor card. `customize.doctorNotice` off: it runs nothing (so nothing is marked seen).
/// Off is the default (Leo 2026-11-25: "make it stop showing the customization not
/// applied/reviewd and shit popup tosts"): the doctor card in Settings shows the findings inline;
/// the toast pops only for someone who turns Customization notices on.
/// At most one run is in flight; loads during a run make one more run after it.
@MainActor
public final class CustomizeDoctorNotice {
    public static let toastID = "customize-doctor"
    /// Settings > Personalization (webviews `categories.ts`: the category that draws
    /// `customizeLibrary`) scrolled to the doctor card.
    public static let route = "#/settings/personalization?focus=card.customizeDoctor"
    nonisolated static let arguments = ["--json", "customize", "doctor", "--announce"]

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: SettingsCustomizeLibrary.Runner
    private let present: @MainActor (String) -> Void
    /// Returns once the app has a window to show the toast in (the app: its first frame), so a
    /// launch run never marks a finding seen before it can be shown.
    private let untilWindow: @MainActor () async -> Void
    /// `customize.doctorNotice` as the last load read it (``follow(_:)`` sets it; tests set it).
    var isOn: @MainActor () -> Bool = { CmuxConfigSnapshot.customizeDoctorNoticeDefault }
    /// The run in flight, nil when idle.
    private(set) var running: Task<Void, Never>?
    /// A load came during the run: run once more after it.
    private var again = false

    /// `present` shows one announcement (tests record it; the app's is ``toast(review:)``).
    init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?,
         runCLI: @escaping SettingsCustomizeLibrary.Runner, untilWindow: @escaping @MainActor () async -> Void,
         present: @escaping @MainActor (String) -> Void) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
        self.untilWindow = untilWindow
        self.present = present
    }

    /// The app's: the bundled CLI run as a child process.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?,
                            untilWindow: @escaping @MainActor () async -> Void, present: @escaping @MainActor (String) -> Void) {
        self.init(cli: cli, settingsFile: settingsFile, runCLI: { try await SettingsCustomizeLibrary.run($0, $1, $2) },
                  untilWindow: untilWindow, present: present)
    }

    /// Runs at the first load and after every later one. The following task holds this object:
    /// it lives with the settings controller, which lives for the app's life.
    public func follow(_ settings: SettingsController) {
        isOn = { [weak settings] in settings?.snapshot.customizeDoctorNotice ?? CmuxConfigSnapshot.customizeDoctorNoticeDefault }
        Task(priority: .utility) { // task-owner: lives with the app's settings controller and holds this notice
            await settings.waitForLoad(atLeast: 1)
            for await _ in ObservationStream({ settings.loadCount }) {
                self.request()
            }
        }
    }

    /// Starts a run, or asks the run in flight for one more after it.
    func request() {
        guard running == nil else {
            again = true
            return
        }
        // Loads before the run starts are this run (it reads the files after them); a load during
        // it starts one more run when it ends.
        running = Task(priority: .utility) { [weak self] in // task-owner: the one run; ends with its CLI run
            self?.again = false
            await self?.runOnce()
            guard let self else { return }
            running = nil
            if again { request() }
        }
    }

    private func runOnce() async {
        await untilWindow()
        guard isOn(), let binary = await cli() else { return }
        let environment = SettingsCustomizeLibrary.environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile())
        guard let result = try? await runCLI(binary, Self.arguments, environment), result.0 == 0,
              let answer = try? JSONValue.parse(result.1),
              let line = Self.announcement(answer, isOn: isOn()) else { return }
        present(line)
    }

    /// The line to show for one `doctor --announce` answer: its `announce`, nil when it is null or
    /// blank or the notice is off.
    nonisolated static func announcement(_ answer: JSONValue, isOn: Bool) -> String? {
        guard isOn, let line = answer["doctor"]?["announce"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return nil }
        return line
    }

    /// The app's presenter: a quiet toast on the key window (else the main or the frontmost one)
    /// whose Review button runs `review` (Settings at the doctor card). With every window closed
    /// nothing shows; the card still lists the finding.
    public static func toast(review: @escaping @MainActor () -> Void) -> @MainActor (String) -> Void {
        { line in
            guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.orderedWindows.first(where: { $0.isVisible }) else { return }
            let toast = CmuxToast(id: CustomizeDoctorNotice.toastID, message: line, action: CmuxToast.Action(title: CustomizeDoctorStrings.review),
                                  duration: .seconds(12))
            let handle = CmuxToastCenter.shared.show(toast, in: window)
            handle.onAction = { review() } // toast-target-allow: the toast names customization problems; Review opens the Settings card that lists them
        }
    }
}

enum CustomizeDoctorStrings {
    static var review: String { String(localized: "customizeDoctor.notice.review", defaultValue: "Review", bundle: .localizedModule) }
}
