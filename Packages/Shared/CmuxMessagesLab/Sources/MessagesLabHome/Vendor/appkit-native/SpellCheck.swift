import AppKit

/// Continuous spell checking for the compose field, off the keystroke frame.
///
/// Messages underlines misspellings while you type. AppKit's own continuous
/// checking (`isContinuousSpellCheckingEnabled`) checks asynchronously, but its
/// NSTextCheckingController does synchronous bookkeeping on every change and
/// selection move (annotated substrings through TextKit 2 temporary
/// attributes, spelling attribute removal, re-marking): about 0.5 ms of main
/// thread per keystroke (Time Profiler, typed bench).
///
/// Here a change only bumps a counter and schedules one check for the next
/// run-loop turn (coalesced: a burst of keystrokes is one check). The check
/// runs in the spell server (`requestChecking`, off main); results come back
/// to main and are applied with `setSpellingState` (the NSTextView API for
/// clients that check on their own), only when they differ from what is shown.
/// As in AppKit, a misspelled word is not marked while the caret is at its end
/// right after typing (it is marked once the word ends or the caret leaves).
/// Ignore and Learn from the context menu use the view's spell document tag.
///
/// `--appkit-spell`: AppKit's own continuous checking (A/B).
final class DeferredSpellChecker {
    static let useAppKit = ProcessInfo.processInfo.arguments.contains("--appkit-spell")
    /// The text above this length is checked around the caret only (a paste stress
    /// must not mark a megabyte on main).
    static let fullCheckLimit = 20_000
    static let windowRadius = 4_000

    private weak var view: NSTextView?
    var enabled = true { didSet { if enabled != oldValue { enabled ? schedule() : clear() } } }
    private var changeCount = 0
    private var scheduled = false
    /// Caret location right after the last edit (the word being typed ends there).
    private var typingEnd = -1
    private var shown: [NSRange] = []
    /// Applied checks, for the bench (latency from change to marks).
    private(set) static var checks = 0, applied = 0

    init(view: NSTextView) { self.view = view }

    func textDidChange() {
        changeCount &+= 1
        typingEnd = view.map { $0.selectedRange().length == 0 ? $0.selectedRange().location : -1 } ?? -1
        schedule()
    }

    func selectionDidChange() {
        guard let v = view, v.selectedRange().location != typingEnd || v.selectedRange().length != 0 else { return }
        // The caret left the word being typed: that word may be marked now.
        if typingEnd >= 0 { typingEnd = -1; schedule() }
    }

    private func schedule() {
        guard enabled, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.run() }
    }

    private func run() {
        scheduled = false
        guard enabled, let v = view else { return }
        if v.hasMarkedText() { return }   // the input method owns the text; checked after it commits
        let text = v.string
        let ns = text as NSString
        guard ns.length > 0 else { apply([], range: NSRange(location: 0, length: 0)); return }
        var range = NSRange(location: 0, length: ns.length)
        if ns.length > DeferredSpellChecker.fullCheckLimit {
            let c = v.selectedRange().location
            let lo = max(0, c - DeferredSpellChecker.windowRadius), hi = min(ns.length, c + DeferredSpellChecker.windowRadius)
            range = ns.paragraphRange(for: NSRange(location: lo, length: hi - lo))
        }
        let count = changeCount, end = typingEnd
        DeferredSpellChecker.checks += 1
        NSSpellChecker.shared.requestChecking(of: text, range: range, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                              options: nil, inSpellDocumentWithTag: v.spellCheckerDocumentTag) { [weak self] _, results, _, _ in
            let found = results.filter { $0.resultType == .spelling }.map(\.range)
            DispatchQueue.main.async { [weak self] in
                // A newer change has its own check pending.
                guard let self, self.changeCount == count else { return }
                self.apply(found.filter { !(end >= 0 && NSMaxRange($0) == end && self.typingEnd == end) }, range: range)
            }
        }
    }

    private func apply(_ ranges: [NSRange], range: NSRange) {
        guard let v = view, ranges != shown else { return }
        let len = (v.string as NSString).length
        DeferredSpellChecker.applied += 1
        v.setSpellingState(0, range: NSIntersectionRange(range, NSRange(location: 0, length: len)))
        for r in ranges where NSMaxRange(r) <= len {
            v.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: r)
        }
        shown = ranges
    }

    private func clear() {
        guard let v = view else { return }
        let len = (v.string as NSString).length
        if len > 0 { v.setSpellingState(0, range: NSRange(location: 0, length: len)) }
        shown = []
    }
}
