public import AppKit
import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// The pull requests whose pages are on in this app (`cmux customize use pr:N`): the `pr-N` entries of
/// the Customization Library that are on, as `cmux --json customize library list` lists them (an
/// entry's `code`, cmux-customize `library/code.rs`). The sidebar's "Experiment on · #N" mark shows
/// them and nothing while there are none (webviews `customizeLibrary.ts` `experimentsOn` counts the
/// same entries); its Off runs `customize library off pr-N` for each, the CLI verb the
/// Customization Library card's switch runs, so the card and the mark never differ.
///
/// It reads the library again only when something can have changed it: at its first mark, when
/// `web-dev.json` changes (``WebDevOverrideWatcher/whenChanged(_:)``: the CLI points it at a PR's pages
/// and back), and after a library change the page or the mark ran
/// (``WebDevOverrideWatcher/libraryChanged()``). It never polls. A read that fails keeps what it had.
@MainActor
public final class CustomizeExperiments {
    /// One PR entry that is on.
    public struct Experiment: Equatable, Sendable {
        /// The library entry's name, `pr-43543`.
        public let name: String
        public let repo: String
        public let pr: Int
        public let title: String
    }

    /// The PR entries that are on, top first.
    public private(set) var on: [Experiment] = []
    /// Each window's mark, with what draws it; a closed window's falls away with its owner.
    private var followers: [(owner: Weak, show: @MainActor ([Experiment]) -> Void)] = []

    private struct Weak { weak var object: AnyObject? }

    private let library: SettingsCustomizeLibrary
    private var reading: Task<Void, Never>?
    private var readAgain = false
    private var started = false
    /// A turn-off runs: another press waits for it (a double click runs `off` once per entry).
    private var turningOff = false

    /// How it follows `web-dev.json` (tests pass their own).
    private let watch: (@escaping @MainActor () -> Void) -> Void

    init(library: SettingsCustomizeLibrary,
         watch: @escaping (@escaping @MainActor () -> Void) -> Void = { WebDevOverrideWatcher.shared.whenChanged($0) }) {
        self.library = library
        self.watch = watch
    }

    /// No read runs or waits (tests).
    var isIdle: Bool { reading == nil }

    /// The app's: the bundled CLI, on the settings file the app reads.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?) {
        self.init(library: SettingsCustomizeLibrary(cli: cli, settingsFile: settingsFile))
    }

    /// Reads the library once and follows the changes that can turn a PR's pages on or off.
    func start() {
        guard !started else { return }
        started = true
        watch { [weak self] in self?.refresh() }
        refresh()
    }

    /// A sidebar's mark: it follows ``on``, a click on it calls `open` (the App opens the Library card at
    /// ``libraryRoute``), and its Off runs ``turnOffAll()``, showing a refusal's words in a toast.
    public func makeMark(open: @escaping @MainActor () -> Void) -> CustomizeExperimentsMarkView {
        start()
        let mark = CustomizeExperimentsMarkView()
        mark.onOpen = open
        mark.onTurnOff = { [weak self, weak mark] in
            guard let self, !self.turningOff else { return }
            self.turningOff = true
            Task { [weak mark] in // task-owner: one turn-off run at a time, bounded by the CLI's deadline; on this main-actor model
                let refused = await self.turnOffAll()
                self.turningOff = false
                guard let first = refused.first, let window = mark?.window else { return }
                _ = CmuxToastCenter.shared.show(CmuxToast(id: "customize-experiments", message: Self.turnOffFailed(first.name),
                                                          detail: first.message, tone: .error), in: window)
            }
        }
        follow(mark) { [weak mark] on in mark?.show(line: Self.line(on), help: Self.help(on), turnOff: Self.turnOffTitle) }
        return mark
    }

    /// Reads the library again; reads asked for while one runs coalesce into one more.
    public func refresh() {
        readAgain = true
        guard reading == nil else { return }
        reading = Task { [weak self] in // task-owner: the one read loop; asks while it runs coalesce
            while let self, self.readAgain {
                self.readAgain = false
                guard let answer = try? await self.library.answer(SettingsCustomizeLibrary.arguments(["verb": "list"])),
                      answer["library"]?["entries"] != nil else { continue }
                self.apply(Self.experiments(in: answer))
            }
            self?.reading = nil
        }
    }

    /// Calls `show` with ``on`` now and each time it changes, while `owner` lives (a window's mark).
    public func follow(_ owner: AnyObject, _ show: @escaping @MainActor ([Experiment]) -> Void) {
        followers.append((owner: Weak(object: owner), show: show))
        show(on)
    }

    private func apply(_ experiments: [Experiment]) {
        guard experiments != on else { return }
        on = experiments
        followers.removeAll { $0.owner.object == nil }
        for follower in followers { follower.show(experiments) }
    }

    /// Turns every PR entry that is on off, one CLI run each (the last one off puts back the app's own
    /// pages), then reads the library again. Answers the entries the CLI refused with its words.
    public func turnOffAll() async -> [(name: String, message: String)] {
        var refused: [(name: String, message: String)] = []
        for experiment in on {
            do {
                let answer = try await library.answer(SettingsCustomizeLibrary.arguments(["verb": "off", "name": .string(experiment.name)]))
                if answer["library"] == nil, let message = answer["message"]?.stringValue {
                    refused.append((experiment.name, message))
                }
            } catch {
                refused.append((experiment.name, String(describing: error)))
            }
        }
        refresh()
        return refused
    }

    /// The PR entries that are on in a `customize library` answer (`{"library": {"entries": …}}`), top first.
    nonisolated static func experiments(in answer: JSONValue) -> [Experiment] {
        (answer["library"]?["entries"]?.arrayValue ?? []).compactMap { entry in
            guard entry["on"]?.boolValue == true, let code = entry["code"], let name = entry["name"]?.stringValue,
                  let pr = code["pr"]?.intValue else { return nil }
            return Experiment(name: name, repo: code["repo"]?.stringValue ?? "", pr: pr, title: code["title"]?.stringValue ?? "")
        }
    }

    // MARK: Words

    /// The mark's line: "Experiment on · #43543" for one, "Experiments on · 3" for more; nil for none.
    public static func line(_ experiments: [Experiment]) -> String? {
        guard let first = experiments.first else { return nil }
        if experiments.count == 1 {
            return "\(text("customizeExperiments.mark.one", "Experiment on")) · #\(first.pr)"
        }
        return "\(text("customizeExperiments.mark.many", "Experiments on")) · \(experiments.count.formatted())"
    }

    /// The mark's tooltip: what it means and what a click does, then each PR's number and title.
    public static func help(_ experiments: [Experiment]) -> String {
        let lead = text("customizeExperiments.help",
                        "Some pages come from an unmerged pull request. Click to see it in the Customization Library.")
        let prs = experiments.map { $0.title.isEmpty ? "#\($0.pr)" : "#\($0.pr) \($0.title)" }
        return ([lead] + prs).joined(separator: "\n")
    }

    public static var turnOffTitle: String { text("customizeExperiments.turnOff", "Off") }

    public static func turnOffFailed(_ name: String) -> String {
        String(format: text("customizeExperiments.turnOffFailed", "Couldn't turn off %@"), name)
    }

    /// Settings > Personalization at the Customization Library card.
    public static let libraryRoute = "#/settings/appearance?focus=card.customizeLibrary"

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }
}
