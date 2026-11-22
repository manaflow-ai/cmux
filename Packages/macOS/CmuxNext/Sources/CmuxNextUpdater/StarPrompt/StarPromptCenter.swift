import AppKit
import CmuxNextCompat
public import Foundation
import Observation

/// The one-time ask to star cmux on GitHub (Lawrence 2026-11-15: "we need to prompt user to star cmux ono
/// github, that they can x out as well, make it look very good and super tasteful. we should remember and
/// dont prompt that multiple times tho"). It is the sidebar's bottom-left notice card, the slot and look of
/// the "Did you know?" tip.
///
/// The rule:
/// - It asks only after real use: at least ``minimumDays`` days since the first launch this record saw and at
///   least ``minimumLaunches`` launches, so never on a first launch or during onboarding.
/// - It shares the tips' budget (`FeatureTipBudget`): no tip in the last 14 days, and once it shows no tip
///   follows for 14 days. While it is offered no tip is picked, so the two never show in one launch.
/// - It asks once, ever: its x (``dismiss()``), its button (``starred()``), or a whole launch on screen
///   (``markShown()`` in one launch, then ``recordLaunch()`` in the next) end it for good.
///
/// ```swift
/// let star = StarPromptCenter(defaults: defaults)
/// star.recordLaunch()
/// star.refresh(budgetOpen: FeatureTipBudget(defaults: defaults).isOpen(at: Date()))
/// if star.isOffered { /* show the card */ }
/// ```
@MainActor @Observable
public final class StarPromptCenter {
    /// The fewest days between the first launch and the ask.
    public static let minimumDays = 3
    /// The fewest launches before the ask.
    public static let minimumLaunches = 5
    /// What the card's button opens: the repository's page on GitHub.
    public static let repositoryURL: URL = {
        var page = URLComponents()
        page.scheme = "https"
        page.host = "github.com"
        page.path = "/manaflow-ai/cmux"
        return page.url ?? URL(fileURLWithPath: "/")
    }()

    /// The card shows now. It stays for the rest of the launch once offered, until its x or its button.
    public private(set) var isOffered = false
    @ObservationIgnored private var record: StarPromptRecord
    @ObservationIgnored private var launchRecorded = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let open: @MainActor (URL) -> Void

    /// - Parameters:
    ///   - defaults: Where the record is kept (the app's defaults; a test's own suite).
    ///   - now: The clock (a fixed date in tests).
    ///   - open: Opens the repository for ``starred()``; nil: the person's default browser, where they are signed
    ///     in to GitHub, off the main thread (a recorder in tests).
    public init(defaults: UserDefaults, now: @escaping () -> Date = Date.init, open: (@MainActor (URL) -> Void)? = nil) {
        self.defaults = defaults
        self.now = now
        self.open = open ?? { NSWorkspace.shared.openInBackground($0) }
        record = StarPromptRecord(defaults: defaults)
    }

    /// The prompt never shows again.
    public var isDone: Bool { record.done }

    /// What is remembered (debug output).
    public var snapshot: StarPromptRecord { record }

    /// Counts this launch, once per center (the App calls it at launch). A prompt that was on screen in an
    /// earlier launch is done.
    public func recordLaunch() {
        guard !launchRecorded else { return }
        launchRecorded = true
        var next = record
        if next.firstLaunchAt == nil { next.firstLaunchAt = now() }
        next.launches += 1
        if let shown = next.shownInLaunch, shown < next.launches { next.done = true }
        store(next)
    }

    /// Offers the card when the rule allows it at this moment. `budgetOpen`: no tip showed in the last 14 days.
    /// An offer already made this launch stays.
    public func refresh(budgetOpen: Bool) {
        guard !isOffered else { return }
        if Self.isEligible(record, at: now(), budgetOpen: budgetOpen) { isOffered = true }
    }

    /// Withdraws an offer not yet on screen (tips were turned off or muted); a shown one stays.
    public func withdraw() {
        guard isOffered, record.shownInLaunch == nil else { return }
        isOffered = false
    }

    /// The card is on screen: from the next launch on it never shows again.
    ///
    /// - Returns: True the first time (the caller spends the tips' budget).
    @discardableResult
    public func markShown() -> Bool {
        guard isOffered, record.shownInLaunch == nil else { return false }
        var next = record
        next.shownInLaunch = max(next.launches, 1)
        store(next)
        return true
    }

    /// The card's x: it never shows again.
    public func dismiss() { finish() }

    /// The card's button: the repository opens in the browser and the ask never shows again.
    public func starred() {
        open(Self.repositoryURL)
        finish()
    }

    /// Whether `record` allows the ask at `date` (pure).
    public static func isEligible(_ record: StarPromptRecord, at date: Date, budgetOpen: Bool) -> Bool {
        guard !record.done, budgetOpen, record.launches >= minimumLaunches, let first = record.firstLaunchAt else { return false }
        return date.timeIntervalSince(first) >= Double(minimumDays) * 86_400
    }

    /// DEV/NIGHTLY (`debug.updater {action: "star"}`, the Toast Playground): shows the card now, whatever the
    /// record says; nothing is written until the card is pressed or shown.
    public func debugShow() {
        isOffered = true
        if record.done || record.shownInLaunch != nil {
            var next = record
            next.done = false
            next.shownInLaunch = nil
            store(next)
        }
    }

    /// DEV/NIGHTLY: forgets everything (a fresh install) and hides the card.
    public func debugReset() {
        StarPromptRecord.remove(from: defaults)
        record = StarPromptRecord()
        launchRecorded = false
        isOffered = false
    }

    private func finish() {
        var next = record
        next.done = true
        store(next)
        isOffered = false
    }

    private func store(_ next: StarPromptRecord) {
        guard next != record else { return }
        record = next
        next.save(to: defaults)
    }
}

extension StarPromptCenter {
    /// The card's title ("Star cmux on GitHub").
    public static var title: String { UpdaterStrings.starTitle }
    /// The card's one quiet line.
    public static var detail: String { UpdaterStrings.starDetail }
    /// The card's one button ("Open GitHub").
    public static var openTitle: String { UpdaterStrings.starOpen }
}
