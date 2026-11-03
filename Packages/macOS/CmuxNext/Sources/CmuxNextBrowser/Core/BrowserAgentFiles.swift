public import Foundation
import CmuxNextWakeups

/// A tab whose page's file choosers an agent can answer (`BrowserAgentFiles`): both engines' tabs.
@MainActor
public protocol BrowserAgentFileChoosing: AnyObject {
    var agentFiles: BrowserAgentFiles { get }
}

/// Files an agent handed a tab for the file chooser its next step opens (`cmux browser <tab> upload`,
/// `browser.page.upload`). While an offer stands, the tab's chooser path (WebKit's `runOpenPanelWith`,
/// Chromium's FILE_DIALOG) takes these files instead of asking the person, once; Playwright's
/// `fileChooser.setFiles`. With no offer the person's picker shows, as before.
@MainActor
public final class BrowserAgentFiles {
    /// How an offer ended.
    public enum Outcome: Equatable, Sendable {
        /// A chooser took these files.
        case chosen([URL])
        /// A chooser opened that cannot take them: it was answered with a cancel.
        case refused(Refusal)
        /// No chooser opened before the offer ended (its time ran out, the open step failed, a newer offer).
        case withdrawn

        /// How a page operation reports it: `chosen`, `withdrawn` or the refusal's code.
        public var code: String {
            switch self {
            case .chosen: "chosen"
            case .withdrawn: "withdrawn"
            case .refused(let refusal): refusal.rawValue
            }
        }
    }

    /// Why a chooser could not take the offered files. The raw value is the control error code.
    public enum Refusal: String, Sendable {
        /// The input takes one file (`multiple` is off) and the offer has several.
        case tooManyFiles = "too_many_files"
        /// The input takes a folder (`webkitdirectory`) and the offer is not one folder.
        case needsFolder = "needs_folder"
        /// The input takes files and the offer has a folder.
        case needsFiles = "needs_files"
        /// The page asked where to save (`showSaveFilePicker`); agents only answer open choosers.
        case saveChooser = "save_chooser"
    }

    /// The standing offer: its id and files (a folder's URL has `hasDirectoryPath`).
    private var offer: (id: Int, files: [URL])?
    private var lastID = 0
    /// Outcomes of ended offers no one awaited yet, by id.
    private var ended: [Int: Outcome] = [:]
    /// Every offer that ended (a few ints per upload).
    private var finished: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Outcome, Never>] = [:]
    /// Runs as an offer starts (true) and ends (false): Chromium sends choosers to the app only while
    /// one stands (`CEFRuntime+FileDialogs`).
    var onArmedChange: ((Bool) -> Void)?

    public init() {}

    /// True while an offer stands.
    public var isArmed: Bool { offer != nil }

    /// Offers `files` to the next chooser, runs `open` (the step that opens it: a click), and waits until a
    /// chooser answers or `limit` passes. `open` returning false (its target was missing) ends the offer at
    /// once. A newer offer, or the caller's cancellation, ends this one as withdrawn.
    public func offer(_ files: [URL], within limit: Duration, clock: any Clock<Duration> = ContinuousClock(),
                      during open: () async throws -> Bool) async throws -> Outcome {
        let id = arm(files)
        let opened: Bool
        do {
            opened = try await open()
        } catch {
            // A chooser that took the files before the click's script failed: the page has them.
            if case .chosen? = ended[id] { return ended.removeValue(forKey: id) ?? .withdrawn }
            end(id, .withdrawn)
            ended[id] = nil
            throw error
        }
        if !opened { end(id, .withdrawn) }
        // A chooser opens within moments of the click or not at all: the offer's deadline.
        let deadline = DemandTimer(owner: "browser.upload.chooser", clock: clock)
        deadline.schedule(after: limit) { @MainActor [weak self] in self?.end(id, .withdrawn) }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome = ended.removeValue(forKey: id) { return continuation.resume(returning: outcome) }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(id, .withdrawn) }
        }
    }

    /// ``offer(_:within:clock:during:)`` with `script` as the open step on `page`: it runs as the agent (an agent
    /// gesture, so the page may open a chooser) and answers `{error}` when its element is missing. Answers the
    /// script's value with the outcome.
    public func offer(_ files: [URL], within limit: Duration, clicking script: String,
                      on page: any BrowserTab) async throws -> (answer: BrowserJSValue, outcome: Outcome) {
        var answer: BrowserJSValue = .null
        let outcome = try await offer(files, within: limit) {
            answer = try await page.evaluate(script, world: .page, gesture: .agent)
            if case .object(let members) = answer, members["error"] != nil { return false }
            return true
        }
        return (answer, outcome)
    }

    /// The tab's chooser path: the offered files when a chooser of this kind can take them, `[]` (answer with a
    /// cancel) when it cannot, nil when no offer stands (ask the person). Either answer ends the offer.
    public func answer(multiple: Bool, folder: Bool, save: Bool) -> [URL]? {
        guard let offer else { return nil }
        let folders = offer.files.filter(\.hasDirectoryPath).count
        let refusal: Refusal? = if save {
            .saveChooser
        } else if folder {
            offer.files.count == 1 && folders == 1 ? nil : .needsFolder
        } else if folders > 0 {
            .needsFiles
        } else if !multiple && offer.files.count > 1 {
            .tooManyFiles
        } else {
            nil
        }
        if let refusal {
            end(offer.id, .refused(refusal))
            return []
        }
        end(offer.id, .chosen(offer.files))
        return offer.files
    }

    /// Ends the standing offer (its tab closed): its upload answers withdrawn at once.
    public func withdraw() {
        if let offer { end(offer.id, .withdrawn) }
    }

    private func arm(_ files: [URL]) -> Int {
        if let offer { end(offer.id, .withdrawn) }
        lastID += 1
        offer = (lastID, files)
        onArmedChange?(true)
        return lastID
    }

    /// Ends offer `id` with `outcome`; later ends of the same offer (a late timer, a cancel) do nothing.
    private func end(_ id: Int, _ outcome: Outcome) {
        guard finished.insert(id).inserted else { return }
        if offer?.id == id {
            offer = nil
            onArmedChange?(false)
        }
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: outcome)
        } else {
            ended[id] = outcome
        }
    }
}
