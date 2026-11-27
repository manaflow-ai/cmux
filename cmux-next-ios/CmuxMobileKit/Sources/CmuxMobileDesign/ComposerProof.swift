#if os(iOS) && DEBUG
import QuartzCore
import UIKit

/// A screen with a composer, driven by `ComposerProof`.
@MainActor public protocol ComposerProofHost: AnyObject {
    /// The view the probe element goes in.
    var proofView: UIView { get }
    /// The composer card's frame in the window, as drawn.
    var proofCardFrame: CGRect { get }
    /// The y in the window of one point of the page's content (the transcript's
    /// or the terminal's): it moves when the rows move.
    var proofContentY: CGFloat? { get }
    func proofSetText(_ text: String)
    func proofSetAttachments(_ count: Int)
    func proofSetKeyboard(_ up: Bool)
    /// The composer's text field: is its caret line inside it?
    var proofField: ComposerReturnTextView? { get }
}

/// The composer height cap and zero-shift proof (DEBUG, `-cmux-mobile-composer-proof`).
/// It drives the screen's composer itself and reports on the `composer.proof.<screen>`
/// element's value, which ComposerHeightCapUITests reads:
/// - `h L=<lines> A=<attachments> kb=<up|down> card=<pt> frac=<card / space above the keyboard> caret=<in|out>`
///   at 1, 5 and 20 lines with 0, 2 and 5 attachments;
/// - `shift L=<lines> <add|remove> A=<n> frames=<frames the page's rows moved> max=<pt>` for
///   1, 2 and 5 attachments, sampled every display frame for 0.8 s after the change.
/// Leo, 2026-11-23: "adding attachments shouldn then expand the [...] composer EVEN TALLER
/// [...] simply have it within the top part of the composer. the inner area grows at the top.
/// no shift, nothing."
@MainActor public enum ComposerProof {
    public static let flag = "-cmux-mobile-composer-proof"
    public static var enabled: Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    private static var running: Set<String> = []

    /// Runs once per screen name.
    public static func start(_ host: ComposerProofHost, screen: String) {
        guard enabled, !running.contains(screen) else { return }
        KeyboardFrameWatch.shared.begin()
        running.insert(screen)
        Task { @MainActor in await run(host, screen: screen) }
    }

    static func text(lines: Int) -> String {
        (1...lines).map { "line \($0)" }.joined(separator: "\n")
    }

    private static func run(_ host: ComposerProofHost, screen: String) async {
        let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "composer.proof.\(screen)"
        probe.accessibilityLabel = "composer proof \(screen)"
        probe.alpha = 0.02
        probe.isUserInteractionEnabled = false
        // In the window, as KeyboardPinTrace's probe: a screen's own view can hide its
        // subviews from accessibility (its own accessibilityElements, a hosting view).
        for _ in 0..<50 where host.proofView.window == nil { await pause(0.1) }
        (host.proofView.window ?? host.proofView).addSubview(probe)
        var lines: [String] = []
        func publish(_ state: String) {
            probe.accessibilityValue = ([state] + lines).joined(separator: "\n")
        }
        publish("running")
        await pause(2)

        // The gallery (`-cmux-mobile-composer-proof-gallery`): the tallest draft with the
        // keyboard up, without then with two attachments, left on screen for the shot.
        // `-cmux-mobile-composer-proof-case L A` instead sets one draft: Leo's 2026-11-23 shot
        // was four thumbnails over five lines with the keyboard up.
        if ProcessInfo.processInfo.arguments.contains("-cmux-mobile-composer-proof-gallery") {
            let args = ProcessInfo.processInfo.arguments
            var cases = [(20, 0), (20, 2)]
            if let at = args.firstIndex(of: "-cmux-mobile-composer-proof-case"), at + 2 < args.count,
               let caseLines = Int(args[at + 1]), let caseAttachments = Int(args[at + 2]) {
                cases = [(caseLines, caseAttachments)]
            }
            host.proofSetKeyboard(true)
            await pause(1.2)
            for (count, attachments) in cases {
                host.proofSetText(text(lines: count))
                host.proofSetAttachments(attachments)
                await pause(1)
                lines.append(measure(host, lines: count, attachments: attachments, keyboard: true))
            }
            publish("done")
            return
        }

        for keyboard in [false, true] {
            host.proofSetKeyboard(keyboard)
            await pause(1.2)
            for count in [1, 5, 20] {
                for attachments in [0, 2, 5] {
                    host.proofSetText(text(lines: count))
                    host.proofSetAttachments(attachments)
                    await pause(0.8)
                    lines.append(measure(host, lines: count, attachments: attachments, keyboard: keyboard))
                    publish("running")
                }
            }
            host.proofSetAttachments(0)
            await pause(0.6)
        }

        // Zero shift: rows do not move when attachments come or go.
        host.proofSetKeyboard(false)
        for count in [1, 20] {
            host.proofSetText(text(lines: count))
            host.proofSetAttachments(0)
            await pause(1.2)
            for attachments in [1, 2, 5] {
                for adding in [true, false] {
                    let sampler = ShiftSampler(host: host)
                    host.proofSetAttachments(adding ? attachments : 0)
                    await pause(0.8)
                    let (frames, max) = sampler.finish()
                    lines.append(String(format: "shift L=%d %@ A=%d frames=%d max=%.1f", count, adding ? "add" : "remove",
                                        attachments, frames, max))
                    publish("running")
                    await pause(0.3)
                }
            }
        }
        host.proofSetText("")
        publish("done")
    }

    /// The card's height and its share of the space above the keyboard (the window's
    /// height with the keyboard down).
    private static func measure(_ host: ComposerProofHost, lines: Int, attachments: Int, keyboard: Bool) -> String {
        let card = host.proofCardFrame
        let window = host.proofView.window
        let windowHeight = window?.bounds.height ?? UIScreen.main.bounds.height
        let keyboardTop = keyboard ? (window.map { keyboardMinY(in: $0) } ?? windowHeight) : windowHeight
        let frac = card.height / max(keyboardTop, 1)
        let caret = host.proofField.map { $0.caretInView ? "in" : "out" } ?? "-"
        return String(format: "h L=%d A=%d kb=%@ card=%.1f frac=%.3f caret=%@", lines, attachments,
                      keyboard ? "up" : "down", card.height, frac, caret)
    }

    /// The keyboard's top in the window, from its last frame notification (the window's
    /// keyboardLayoutGuide read 0 here: no view constrains to it).
    private static func keyboardMinY(in window: UIWindow) -> CGFloat {
        guard let frame = KeyboardFrameWatch.shared.endFrame else { return window.bounds.height }
        return min(window.bounds.height, window.convert(frame, from: nil).minY)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor private final class KeyboardFrameWatch {
    static let shared = KeyboardFrameWatch()
    private(set) var endFrame: CGRect?
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                                       object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { KeyboardFrameWatch.shared.endFrame = frame }
        }
    }
}

/// The page's content position on every display frame from the change on.
@MainActor private final class ShiftSampler: NSObject {
    private weak var host: ComposerProofHost?
    private var link: CADisplayLink?
    private let start: CGFloat?
    private var frames = 0
    private var maxShift: CGFloat = 0

    init(host: ComposerProofHost) {
        self.host = host
        start = host.proofContentY
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let start, let y = host?.proofContentY else { return }
        let shift = abs(y - start)
        if shift > 0.5 { frames += 1 }
        maxShift = max(maxShift, shift)
    }

    func finish() -> (Int, CGFloat) {
        tick()
        link?.invalidate()
        link = nil
        return (frames, maxShift)
    }
}
#endif
